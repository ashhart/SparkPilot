use super::*;

/// Descriptor-level (fstat) regular-file check: never trusts the path.
pub(super) fn ensure_regular_file(file: &std::fs::File) -> Result<()> {
    if !file.metadata()?.is_file() {
        return Err(DownloadError::Source(
            "partial entry is not a regular file".into(),
        ));
    }
    Ok(())
}

/// Hash only regular files opened without following links so concurrent entry swaps cannot redirect reads.
#[cfg(unix)]
pub(super) fn sha256_regular_no_follow(path: &Path) -> Result<String> {
    use std::os::unix::fs::OpenOptionsExt;
    let mut file = std::fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(path)?;
    if !file.metadata()?.is_file() {
        return Err(DownloadError::Source(
            "staged entry is not a regular file".into(),
        ));
    }
    Ok(sha256_reader(&mut file)?)
}

#[cfg(not(unix))]
pub(super) fn sha256_regular_no_follow(path: &Path) -> Result<String> {
    sha256_file(path)
}

/// Sync directory entries on Unix to persist renames; other platforms still receive atomic renames of synced contents.
#[cfg(unix)]
pub(super) fn sync_directory(parent: Option<&Path>) -> Result<()> {
    let Some(dir) = parent else {
        return Err(DownloadError::Internal(
            "staged file has no parent directory".into(),
        ));
    };
    std::fs::File::open(dir)?.sync_all()?;
    Ok(())
}

#[cfg(not(unix))]
pub(super) fn sync_directory(_parent: Option<&Path>) -> Result<()> {
    Ok(())
}

/// Materialize verified staged files into a content-addressed immutable snapshot.
pub fn materialise_snapshot(
    staged: &[(String, PathBuf)],
    models_root: &Path,
    model_id: &str,
    source_revision: &str,
) -> Result<()> {
    // Remove redundant staged copies after the snapshot owns their verified content.
    let mut duplicates: Vec<&PathBuf> = Vec::new();
    for (_relative, verified_copy) in staged {
        let digest = sha256_regular_no_follow(verified_copy)?;
        let blob_path =
            crate::model_paths::blob_path(models_root, &digest).map_err(DownloadError::Internal)?;
        if let Some(blob_dir) = blob_path.parent() {
            std::fs::create_dir_all(blob_dir)?;
        }
        publish_verified_blob(verified_copy, &blob_path, &digest)?;
        if !same_inode(verified_copy, &blob_path)? {
            duplicates.push(verified_copy);
        }
    }

    // Use per-file symlinks for deterministic snapshot names.
    let snapshot_dir = crate::model_paths::snapshot_path(models_root, model_id, source_revision)
        .map_err(DownloadError::Internal)?;
    std::fs::create_dir_all(&snapshot_dir)?;
    for (relative, verified_copy) in staged {
        let digest = sha256_file(verified_copy)?;
        let dest = crate::model_paths::relative_join(&snapshot_dir, relative)
            .map_err(DownloadError::Internal)?;
        if let Some(parent) = dest.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let blob =
            crate::model_paths::blob_path(models_root, &digest).map_err(DownloadError::Internal)?;
        if dest.exists() {
            std::fs::remove_file(&dest)?;
        }
        std::fs::hard_link(&blob, &dest).map_err(DownloadError::Io)?;
    }

    // Retain same-inode staged links for reuse and delete copies that duplicate full model storage.
    for verified_copy in duplicates {
        if let Err(error) = std::fs::remove_file(verified_copy) {
            tracing::warn!(
                path = %verified_copy.display(),
                %error,
                "could not remove a staged download after copying it into the blob store"
            );
        }
    }
    Ok(())
}

fn publish_verified_blob(source: &Path, blob: &Path, digest: &str) -> Result<()> {
    let exists = match std::fs::symlink_metadata(blob) {
        Ok(metadata) if metadata.is_file() => {
            if sha256_regular_no_follow(blob)? == digest {
                return Ok(());
            }
            true
        }
        Ok(_) => {
            return Err(DownloadError::Source(
                "blob entry is not a regular file".into(),
            ));
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => false,
        Err(error) => return Err(error.into()),
    };
    let mut input = std::fs::OpenOptions::new();
    input.read(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        input.custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC);
    }
    let mut input = input.open(source)?;
    ensure_regular_file(&input)?;
    input.sync_all()?;
    if !exists && std::fs::hard_link(source, blob).is_ok() {
        return sync_directory(blob.parent());
    }
    let parent = blob
        .parent()
        .ok_or_else(|| DownloadError::Internal("blob has no parent".into()))?;
    let mut temporary = tempfile::NamedTempFile::new_in(parent)?;
    std::io::copy(&mut input, temporary.as_file_mut())?;
    temporary.as_file().sync_all()?;
    if sha256_regular_no_follow(temporary.path())? != digest {
        return Err(DownloadError::Source(
            "blob changed while being published".into(),
        ));
    }
    temporary
        .persist(blob)
        .map_err(|error| DownloadError::Io(error.error))?;
    sync_directory(Some(parent))
}

#[cfg(unix)]
pub(super) fn same_inode(left: &Path, right: &Path) -> Result<bool> {
    use std::os::unix::fs::MetadataExt;
    let left = std::fs::metadata(left)?;
    let right = std::fs::metadata(right)?;
    Ok(left.dev() == right.dev() && left.ino() == right.ino())
}

#[cfg(not(unix))]
pub(super) fn same_inode(_left: &Path, _right: &Path) -> Result<bool> {
    Ok(false)
}

pub fn sha256_file(path: &Path) -> Result<String> {
    let mut file = std::fs::File::open(path)?;
    Ok(sha256_reader(&mut file)?)
}

pub(super) fn sha256_reader(reader: &mut impl std::io::Read) -> std::io::Result<String> {
    use sha2::{Digest, Sha256};
    let mut hasher = Sha256::new();
    let mut buf = [0u8; 64 * 1024];
    loop {
        let n = reader.read(&mut buf)?;
        if n == 0 {
            break;
        }
        hasher.update(&buf[..n]);
    }
    Ok(hex::encode(hasher.finalize()))
}
