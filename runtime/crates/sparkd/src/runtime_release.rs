//! Stage validated release ids and fixed files; privd seals and re-verifies trust, manifest, digest and signature before dpkg.

use std::fs::{self, OpenOptions};
use std::io::Write;
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::sync::{Mutex, OnceLock};

use spark_privd::update::{STAGED_MANIFEST, STAGED_PACKAGE, STAGED_SIGNATURE, validate_release_id};

pub const MAX_APP_MANIFEST_BYTES: usize = 1 << 20;
pub const MAX_APP_PACKAGE_BYTES: usize = 10 << 20;
pub const MAX_APP_SIGNATURE_BYTES: usize = 1 << 20;

#[derive(Debug)]
pub struct RuntimeReleaseBundle {
    pub release_id: String,
    pub manifest: Vec<u8>,
    pub package: Vec<u8>,
    pub signature: Vec<u8>,
}

#[derive(Debug, thiserror::Error)]
pub enum RuntimeReleaseStageError {
    #[error("invalid release id: {0}")]
    InvalidReleaseId(String),
    #[error("{name} is empty or exceeds its {limit}-byte limit")]
    InvalidSize { name: &'static str, limit: usize },
    #[error("the staging root is not a regular directory")]
    InvalidStagingRoot,
    #[error("staging I/O failed: {0}")]
    Io(#[from] std::io::Error),
}

impl RuntimeReleaseBundle {
    pub fn validate(&self) -> Result<(), RuntimeReleaseStageError> {
        validate_release_id(&self.release_id)
            .map_err(|error| RuntimeReleaseStageError::InvalidReleaseId(error.to_string()))?;
        bounded("manifest", &self.manifest, MAX_APP_MANIFEST_BYTES)?;
        bounded("package", &self.package, MAX_APP_PACKAGE_BYTES)?;
        bounded("signature", &self.signature, MAX_APP_SIGNATURE_BYTES)?;
        Ok(())
    }
}

fn bounded(name: &'static str, bytes: &[u8], limit: usize) -> Result<(), RuntimeReleaseStageError> {
    if bytes.is_empty() || bytes.len() > limit {
        return Err(RuntimeReleaseStageError::InvalidSize { name, limit });
    }
    Ok(())
}

/// Serialize concurrent submissions and publish either no complete release or all three fixed staged files.
pub fn stage_runtime_release(
    root: &Path,
    bundle: &RuntimeReleaseBundle,
) -> Result<PathBuf, RuntimeReleaseStageError> {
    static STAGING_LOCK: OnceLock<Mutex<()>> = OnceLock::new();
    let _guard = STAGING_LOCK
        .get_or_init(|| Mutex::new(()))
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    bundle.validate()?;

    ensure_root(root)?;
    let temporary = root.join(format!(
        ".{}.{}.part",
        bundle.release_id,
        uuid::Uuid::new_v4()
    ));
    fs::create_dir(&temporary)?;
    // Use group-readable, non-group-writable staging because privd reads through sparkd group membership without DAC override.
    fs::set_permissions(&temporary, fs::Permissions::from_mode(0o750))?;

    let staged = (|| {
        write_new(&temporary.join(STAGED_MANIFEST), &bundle.manifest)?;
        write_new(&temporary.join(STAGED_PACKAGE), &bundle.package)?;
        write_new(&temporary.join(STAGED_SIGNATURE), &bundle.signature)?;
        sync_directory(&temporary)?;

        let destination = root.join(&bundle.release_id);
        remove_entry(&destination)?;
        fs::rename(&temporary, &destination)?;
        sync_directory(root)?;
        Ok(destination)
    })();
    if staged.is_err() {
        let _ = fs::remove_dir_all(&temporary);
    }
    staged
}

fn ensure_root(root: &Path) -> Result<(), RuntimeReleaseStageError> {
    match fs::symlink_metadata(root) {
        Ok(metadata) if metadata.is_dir() && !metadata.file_type().is_symlink() => {}
        Ok(_) => return Err(RuntimeReleaseStageError::InvalidStagingRoot),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            fs::create_dir_all(root)?;
        }
        Err(error) => return Err(error.into()),
    }
    let metadata = fs::symlink_metadata(root)?;
    if !metadata.is_dir() || metadata.file_type().is_symlink() {
        return Err(RuntimeReleaseStageError::InvalidStagingRoot);
    }
    fs::set_permissions(root, fs::Permissions::from_mode(0o750))?;
    Ok(())
}

fn write_new(path: &Path, bytes: &[u8]) -> Result<(), std::io::Error> {
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        // Grant helper group read access without relying on root DAC override.
        .mode(0o640)
        .open(path)?;
    file.write_all(bytes)?;
    file.sync_all()
}

fn remove_entry(path: &Path) -> Result<(), std::io::Error> {
    let metadata = match fs::symlink_metadata(path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(error) => return Err(error),
    };
    if metadata.is_dir() && !metadata.file_type().is_symlink() {
        fs::remove_dir_all(path)
    } else {
        fs::remove_file(path)
    }
}

fn sync_directory(path: &Path) -> Result<(), std::io::Error> {
    OpenOptions::new().read(true).open(path)?.sync_all()
}
