use super::*;

pub(super) struct StagedRelease<'a> {
    pub(super) staging_root: &'a Path,
    pub(super) state_root: &'a Path,
    pub(super) service_uid: u32,
    pub(super) installed_trust_root: &'a Path,
}

impl StagedRelease<'_> {
    pub(super) fn validate_staging(&self, staged: &Path) -> Result<(), UpdateError> {
        let meta = fs::symlink_metadata(staged).map_err(|error| {
            UpdateError::refused(format!(
                "UPDATE_STAGING_INVALID staged path is unusable: {error}"
            ))
        })?;
        if meta.file_type().is_symlink() || !meta.is_dir() {
            return Err(UpdateError::refused(
                "UPDATE_STAGING_INVALID staging path is not a real directory",
            ));
        }
        let mode = meta.permissions().mode();
        if mode & 0o022 != 0 {
            return Err(UpdateError::refused(
                "UPDATE_STAGING_INVALID staging directory is group/other-writable",
            ));
        }
        if meta.uid() != self.service_uid {
            return Err(UpdateError::refused(format!(
                "UPDATE_STAGING_INVALID staging directory is owned by uid {}, expected {}",
                meta.uid(),
                self.service_uid
            )));
        }
        for (name, bound) in [
            (STAGED_MANIFEST, MAX_MANIFEST_BYTES),
            (STAGED_SIGNATURE, MAX_SIGNATURE_BYTES),
            (STAGED_PACKAGE, MAX_PACKAGE_BYTES),
        ] {
            let path = staged.join(name);
            let meta = fs::symlink_metadata(&path).map_err(|error| {
                UpdateError::refused(format!(
                    "UPDATE_STAGING_INVALID {name} is unusable: {error}"
                ))
            })?;
            if meta.file_type().is_symlink() || !meta.is_file() {
                return Err(UpdateError::refused(format!(
                    "UPDATE_STAGING_INVALID {name} is not a regular file"
                )));
            }
            if meta.uid() != self.service_uid {
                return Err(UpdateError::refused(format!(
                    "UPDATE_STAGING_INVALID {name} is owned by uid {}, expected {}",
                    meta.uid(),
                    self.service_uid
                )));
            }
            if meta.len() > bound {
                return Err(UpdateError::refused(format!(
                    "UPDATE_STAGING_INVALID {name} is {} bytes, above the {bound}-byte bound",
                    meta.len()
                )));
            }
        }
        Ok(())
    }

    pub(super) fn assert_installed_trust_root(&self) -> Result<(), UpdateError> {
        let meta = fs::symlink_metadata(self.installed_trust_root).map_err(|error| {
            UpdateError::refused(format!(
                "UPDATE_NO_TRUST_ROOT installed trust root is unavailable: {error}"
            ))
        })?;
        if meta.file_type().is_symlink() || !meta.is_file() {
            return Err(UpdateError::refused(
                "UPDATE_NO_TRUST_ROOT installed trust root is not a regular file",
            ));
        }
        Ok(())
    }

    pub(super) fn seal(&self, release_id: &str) -> Result<Seal, UpdateError> {
        let _staging_guard = acquire_staging_lock(self.staging_root, false)?;
        self.validate_staging(&self.staging_root.join(release_id))?;
        let apply_root = self.state_root.join("apply").join(release_id);
        fs::create_dir_all(&apply_root)?;
        fs::set_permissions(&apply_root, std::fs::Permissions::from_mode(0o700))?;
        let staged = self.staging_root.join(release_id);
        for name in [STAGED_MANIFEST, STAGED_SIGNATURE, STAGED_PACKAGE] {
            self.copy_sealed(&staged.join(name), &apply_root.join(name))?;
        }
        let sealed_package = apply_root.join(STAGED_PACKAGE);
        Ok(Seal {
            directory: apply_root,
            package: sealed_package,
        })
    }

    pub(super) fn copy_sealed(&self, source: &Path, destination: &Path) -> Result<(), UpdateError> {
        // Atomically replace seals within root-owned storage using no-follow writes.
        let temp = destination.with_extension("tmp");
        let mut input = fs::OpenOptions::new()
            .read(true)
            // Open nonblocking so a FIFO swapped into staging cannot hang the worker before fstat rejects it.
            .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
            .open(source)?;
        if !input.metadata()?.is_file() {
            return Err(UpdateError::refused(
                "UPDATE_STAGING_INVALID source changed to a non-regular file while sealing",
            ));
        }
        let mut output = fs::OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .custom_flags(libc::O_NOFOLLOW)
            .mode(0o600)
            .open(&temp)?;
        std::io::copy(&mut input, &mut output)?;
        output.sync_all()?;
        fs::rename(&temp, destination)?;
        Ok(())
    }
}
