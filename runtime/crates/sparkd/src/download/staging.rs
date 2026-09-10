use super::*;

/// Resume consistent partial files and return verified relative-path and blob-path pairs.
pub fn stage_files(
    recipe: &ModelRecipe,
    files: &[RemoteFile],
    source: &dyn FileSource,
    work_dir: &Path,
    ctx: &DownloadContext,
    progress: &dyn ProgressSink,
) -> Result<Vec<(String, PathBuf)>> {
    stage_files_with_credential(recipe, files, source, work_dir, ctx, progress, None)
}

pub(super) fn stage_files_with_credential(
    recipe: &ModelRecipe,
    files: &[RemoteFile],
    source: &dyn FileSource,
    work_dir: &Path,
    ctx: &DownloadContext,
    progress: &dyn ProgressSink,
    credential_path: Option<&Path>,
) -> Result<Vec<(String, PathBuf)>> {
    std::fs::create_dir_all(work_dir)?;
    let mut staged = Vec::with_capacity(files.len());

    // Use signed manifest totals and accumulated file bytes so progress remains consistent across file boundaries.
    let grand_total = total_bytes(files);
    let mut completed: u64 = 0;
    // Retain a high-water mark so disappearing reusable files cannot make reported progress regress.
    let high_water = std::cell::Cell::new(0.0_f64);
    let report = |stage: &str, done: u64| {
        if grand_total == 0 {
            progress.stage(stage, None);
            return;
        }
        let fraction = (done as f64 / grand_total as f64).clamp(0.0, 1.0);
        let fraction = fraction.max(high_water.get());
        high_water.set(fraction);
        progress.stage(stage, Some(fraction));
    };

    for (index, file) in files.iter().enumerate() {
        ctx.check_cancel()?;
        crate::model_paths::validate_sha256(&file.sha256).map_err(DownloadError::Source)?;
        let target = crate::model_paths::relative_join(work_dir, &file.relative_path)
            .map_err(DownloadError::Source)?;
        let mut part_name = target.as_os_str().to_owned();
        part_name.push(".part");
        let part_path = PathBuf::from(part_name);
        if let Some(parent) = target.parent() {
            std::fs::create_dir_all(parent)?;
        }

        // Reverify reusable entries as regular files with matching full digests; mutable staging names alone prove no integrity.
        if let Ok(meta) = std::fs::symlink_metadata(&target) {
            let verified = meta.is_file()
                && meta.len() == file.size_bytes
                && matches!(sha256_regular_no_follow(&target), Ok(digest) if digest.eq_ignore_ascii_case(&file.sha256));
            if verified {
                staged.push((file.relative_path.clone(), target));
                completed = completed.saturating_add(file.size_bytes);
                report("downloading", completed);
                continue;
            }
            if meta.is_dir() {
                std::fs::remove_dir(&target)?;
            } else {
                std::fs::remove_file(&target)?;
            }
        }

        // Remove nonregular partial entries without following them and use O_NOFOLLOW again to reject swap races.
        if let Ok(meta) = std::fs::symlink_metadata(&part_path)
            && !meta.is_file()
        {
            if meta.is_dir() {
                std::fs::remove_dir(&part_path)?;
            } else {
                std::fs::remove_file(&part_path)?;
            }
        }

        // Resume only partials no larger than the manifest's expected size.
        let (mut done, retry) = resume_point(&part_path, file);
        ctx.fetches.fetch_add(retry, Ordering::SeqCst);

        // Open partials with O_NOFOLLOW so planted source-manifest names cannot redirect writes.
        const CHUNK: usize = 8 * 1024 * 1024;
        let mut writer = open_partial_for_resume(&part_path)?;
        use std::io::{Seek, SeekFrom, Write};
        if done == 0 {
            // Truncate zero-offset retries so stale trailing bytes cannot cause repeated digest failures.
            writer.set_len(0)?;
        }
        writer.seek(SeekFrom::Start(done))?;

        while done < file.size_bytes {
            ctx.check_cancel()?;
            let want = (file.size_bytes - done).min(CHUNK as u64) as usize;
            let bytes = source
                .fetch_with_credential(recipe, file, Some((done, want)), credential_path)
                .map_err(DownloadError::Source)?;
            ctx.check_cancel()?;
            if bytes.is_empty() || bytes.len() > want {
                return Err(DownloadError::Source(format!(
                    "source returned an invalid {} bytes for a {want}-byte range of {:?}",
                    bytes.len(),
                    file.relative_path
                )));
            }
            writer.write_all(&bytes)?;
            done += bytes.len() as u64;
            progress
                .note(
                    &file.relative_path,
                    index,
                    files.len(),
                    done,
                    file.size_bytes,
                )
                .map_err(DownloadError::Internal)?;
            report("downloading", completed.saturating_add(done));
        }
        writer.flush().map_err(DownloadError::Io)?;
        // Sync verified bytes before publishing their staged filename.
        writer.sync_all()?;

        // Verify each file before staging while retaining install-wide progress across phase labels.
        report("verifying", completed.saturating_add(file.size_bytes));
        let digest = sha256_file(&part_path)?;
        if !digest.eq_ignore_ascii_case(&file.sha256) {
            // Delete corrupt partials so digest failures never materialize and retries start cleanly.
            let _ = std::fs::remove_file(&part_path);
            return Err(DownloadError::DigestMismatch {
                file: file.relative_path.clone(),
                want: file.sha256.clone(),
                got: digest,
            });
        }
        std::fs::rename(&part_path, &target)?;
        // Sync the publishing rename after the file contents are durable.
        sync_directory(target.parent())?;
        staged.push((file.relative_path.clone(), target));
        completed = completed.saturating_add(file.size_bytes);
    }
    Ok(staged)
}

pub(super) fn resume_point(part_path: &Path, file: &RemoteFile) -> (u64, usize) {
    // Inspect without following links and rely on O_NOFOLLOW at open to reject subsequent swaps.
    let meta = std::fs::symlink_metadata(part_path).ok();
    match meta {
        // Resume bounded partials, including complete ones pending verification; restart oversized leftovers and verify every final digest.
        Some(m) if m.is_file() && m.len() <= file.size_bytes => (m.len(), 1),
        _ => (0, 0),
    }
}

/// Create private no-follow partials and verify descriptor type before seeking, truncating or writing.
#[cfg(unix)]
pub(super) fn open_partial_for_resume(part_path: &Path) -> Result<std::fs::File> {
    use std::os::unix::fs::OpenOptionsExt;
    let file = std::fs::OpenOptions::new()
        .create(true)
        .write(true)
        .truncate(false)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(part_path)?;
    ensure_regular_file(&file)?;
    Ok(file)
}

#[cfg(not(unix))]
pub(super) fn open_partial_for_resume(part_path: &Path) -> Result<std::fs::File> {
    let file = std::fs::OpenOptions::new()
        .create(true)
        .write(true)
        .truncate(false)
        .open(part_path)?;
    ensure_regular_file(&file)?;
    Ok(file)
}
