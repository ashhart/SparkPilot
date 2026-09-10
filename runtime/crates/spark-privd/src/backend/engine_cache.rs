use super::*;

pub(super) struct EngineCache<'a> {
    pub(super) engine_cache_root: &'a Path,
    pub(super) service_gid: u32,
}

impl EngineCache<'_> {
    pub(super) fn prepare_for(&self, operation: &PrivilegedOperation) -> Result<(), BackendError> {
        use std::os::unix::fs::PermissionsExt;
        let path = scoped_path(self.engine_cache_root, operation)?;
        let parent = path.parent().expect("scoped cache parent");
        std::fs::create_dir_all(parent)?;
        let metadata = std::fs::symlink_metadata(parent)?;
        if metadata.file_type().is_symlink() || !metadata.is_dir() {
            return Err(BackendError::Failure(
                "scoped engine cache must not be a link".into(),
            ));
        }
        std::fs::set_permissions(parent, std::fs::Permissions::from_mode(0o700))?;
        EngineCache {
            engine_cache_root: &path,
            service_gid: self.service_gid,
        }
        .prepare_engine_cache()
    }

    /// Prepare the persistent compile cache at execution time; planning must not modify the filesystem.
    pub(super) fn prepare_engine_cache(&self) -> Result<(), BackendError> {
        use std::os::unix::fs::{MetadataExt, PermissionsExt};

        let root = &self.engine_cache_root;
        std::fs::create_dir_all(root).map_err(|error| {
            BackendError::Failure(format!(
                "could not create the engine cache {}: {error}",
                root.display()
            ))
        })?;
        let metadata = std::fs::symlink_metadata(root)
            .map_err(|error| BackendError::Failure(error.to_string()))?;
        if metadata.file_type().is_symlink() || !metadata.is_dir() {
            return Err(BackendError::Failure(format!(
                "the engine cache {} must be a directory, not a link",
                root.display()
            )));
        }
        // Share through the existing service group; the helper lacks CAP_CHOWN and cannot transfer directory ownership.
        if metadata.gid() != self.service_gid {
            return Err(BackendError::Failure(format!(
                "the engine cache {} belongs to group {}, expected {}; remove it and start again",
                root.display(),
                metadata.gid(),
                self.service_gid
            )));
        }
        if metadata.permissions().mode() & 0o777 != 0o770 {
            std::fs::set_permissions(root, std::fs::Permissions::from_mode(0o770))
                .map_err(|error| BackendError::Failure(error.to_string()))?;
        }
        Ok(())
    }
}

/// Never reuse the legacy shared cache, including when an older engine is still running.
pub(super) fn scoped_path(
    root: &Path,
    operation: &PrivilegedOperation,
) -> Result<PathBuf, BackendError> {
    use sha2::{Digest, Sha256};
    let PrivilegedOperation::StartModel {
        recipe_id,
        image_digest,
        model_snapshot,
        ..
    } = operation
    else {
        return Err(BackendError::InvalidInput(
            "cache requires a model launch".into(),
        ));
    };
    let mut identity = Sha256::new();
    for value in [recipe_id, image_digest, model_snapshot] {
        identity.update(value.as_bytes());
        identity.update([0]);
    }
    if qwen::selected(operation) {
        identity.update(include_bytes!(
            "../../../../../packaging/engines/qwen38/sources.json"
        ));
    }
    let name = root
        .file_name()
        .and_then(|v| v.to_str())
        .ok_or_else(|| BackendError::InvalidInput("invalid cache root".into()))?;
    Ok(root
        .with_file_name(format!("{name}-v2"))
        .join(format!("{:x}", identity.finalize())))
}
