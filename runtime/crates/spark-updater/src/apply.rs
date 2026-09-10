//! Verify and stage fixed release files before typed privileged handoff; the helper re-verifies before installing with dpkg.

use std::fs;
use std::path::Path;

use spark_installer::manifest::ReleaseManifest;
use spark_installer::trust::ReleaseTrustRoot;
use spark_installer::verify::{
    ArtifactVerification, TrustRootSource, read_signature, verify_artifact,
};
use spark_privd::protocol::{PrivilegedOperation, PrivilegedResponse};
use sparkd::privd::PrivilegedClient;
use thiserror::Error;

/// Keep the staging root identical to spark-privd's update boundary.
pub const DEFAULT_STAGING_ROOT: &str = "/var/cache/spark-runtime/updates";
/// Match spark-privd's fixed STAGED_* filenames.
pub const STAGED_MANIFEST: &str = "manifest.json";
pub const STAGED_PACKAGE: &str = "package.deb";
pub const STAGED_SIGNATURE: &str = "package.deb.sig";
/// Reserve unpacking headroom while the old package remains present; dpkg still makes the final disk decision.
pub const DISK_RESERVE_BYTES: u64 = 4 << 30;

#[derive(Debug, Error)]
pub enum ApplyError {
    #[error("{0}")]
    Message(String),
    #[error(transparent)]
    Io(#[from] std::io::Error),
}

impl From<String> for ApplyError {
    fn from(message: String) -> Self {
        ApplyError::Message(message)
    }
}

impl From<&str> for ApplyError {
    fn from(message: &str) -> Self {
        ApplyError::Message(message.to_owned())
    }
}

/// Use fixed product paths, with explicit path injection for isolated tests.
pub struct ApplyRequest<'a> {
    pub manifest_path: &'a Path,
    pub package_path: &'a Path,
    pub signature_path: &'a Path,
    /// Require a regular installed trust-root file and refuse missing or redirected trust.
    pub trust_root: &'a Path,
    /// Use the explicit release id or derive channel-version.
    pub release_id: Option<&'a str>,
    pub staging_root: &'a Path,
    /// Privileged helper socket.
    pub privileged_socket: &'a Path,
}

/// Verify, stage and submit one signed update, returning helper JSON on acceptance or a refusal reason.
pub fn run_apply(request: &ApplyRequest<'_>) -> Result<serde_json::Value, ApplyError> {
    // The trust root must be a regular file we did not choose.
    let root_meta = match fs::symlink_metadata(request.trust_root) {
        Ok(meta) => meta,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            return Err(ApplyError::from(format!(
                "UPDATE_NO_TRUST_ROOT {} is not present",
                request.trust_root.display()
            )));
        }
        Err(error) => return Err(ApplyError::from(error.to_string())),
    };
    if root_meta.is_symlink() || !root_meta.is_file() {
        return Err(ApplyError::from(format!(
            "UPDATE_NO_TRUST_ROOT {} is not a regular file",
            request.trust_root.display()
        )));
    }

    let root = ReleaseTrustRoot::load(request.trust_root)
        .map_err(|error| ApplyError::from(error.to_string()))?;
    let now = time::OffsetDateTime::now_utc();
    let manifest_bytes = fs::read(request.manifest_path)?;

    // Verify the manifest signature and channel/key-purpose policy before trusting artifact digests.
    let verified = root
        .verify_manifest(&manifest_bytes, now)
        .map_err(|error| ApplyError::from(error.to_string()))?;
    // Require verified artifact architecture, size, digest and detached signature.
    let artifact = verified
        .manifest
        .artifact(None)
        .map_err(|error| ApplyError::from(error.to_string()))?;

    let signature_bytes = read_signature(request.signature_path)
        .map_err(|error| ApplyError::from(error.to_string()))?;
    verify_artifact(
        request.package_path,
        &ArtifactVerification {
            artifact,
            channel: &verified.manifest.channel,
            trust_root: &root,
            trust_root_source: TrustRootSource::Installed,
            signature: &signature_bytes,
            key_id: &verified.key_id,
            at: now,
        },
    )
    .map_err(|error| ApplyError::from(error.to_string()))?;

    // Deterministic release id: same release, same staging, same retry path.
    let release_id = request
        .release_id
        .map(str::to_owned)
        .unwrap_or_else(|| derived_release_id(&verified.manifest, &artifact.name));
    spark_privd::update::validate_release_id(&release_id)
        .map_err(|error| ApplyError::from(error.to_string()))?;

    // §45.2 step 3: a coarse disk pre-flight; `dpkg` remains authoritative.
    ensure_disk_headroom(request.package_path, request.staging_root)?;

    // Stage fixed filenames beneath the fixed root so the helper needs only the release id.
    let staged_dir = request.staging_root.join(&release_id);
    refuse_sources_inside_staging(
        &staged_dir,
        [
            request.manifest_path,
            request.package_path,
            request.signature_path,
        ],
    )?;
    stage_release(&staged_dir, &manifest_bytes, request)?;

    // Submit to the privileged boundary; the helper re-verifies everything.
    let client = PrivilegedClient::new(request.privileged_socket);
    let response: PrivilegedResponse = client
        .call(PrivilegedOperation::InstallRuntimeUpdate {
            request_id: uuid::Uuid::new_v4(),
            release_id,
        })
        .map_err(|error| ApplyError::from(format!("privileged install request failed: {error}")))?;

    // Treat accepted:false as failure even when the response was delivered successfully.
    if let Some(refusal) = refusal(&response) {
        return Err(refusal);
    }

    serde_json::to_value(&response).map_err(|error| ApplyError::from(error.to_string()))
}

/// Interpret helper acceptance separately from transport success.
fn refusal(response: &PrivilegedResponse) -> Option<ApplyError> {
    if response.accepted {
        return None;
    }
    Some(ApplyError::from(format!(
        "privileged install refused: {}: {}",
        response.code, response.message
    )))
}

/// Refuse sources inside existing staging before recreation deletes them; missing paths are left for later reads to diagnose.
fn refuse_sources_inside_staging(staged_dir: &Path, sources: [&Path; 3]) -> Result<(), ApplyError> {
    let Ok(staged) = fs::canonicalize(staged_dir) else {
        return Ok(());
    };
    for source in sources {
        if let Ok(source) = fs::canonicalize(source)
            && source.starts_with(&staged)
        {
            return Err(ApplyError::from(format!(
                "{} is inside {}, which staging replaces; copy the release elsewhere first",
                source.display(),
                staged.display()
            )));
        }
    }
    Ok(())
}

/// Derive deterministic channel-package-version ids; the caller rejects invalid ids without rewriting them.
fn derived_release_id(manifest: &ReleaseManifest, artifact_name: &str) -> String {
    manifest.release_id_for_artifact(artifact_name)
}

fn ensure_disk_headroom(package: &Path, staging_root: &Path) -> Result<(), ApplyError> {
    let package_size = fs::metadata(package)?.len();
    let staging_parent = staging_root.parent().unwrap_or(staging_root);
    // Check both staging and root filesystems because package copying and unpacking may use separate mounts.
    let mut tightest: Option<(&Path, u64)> = None;
    for path in [staging_parent, Path::new("/")] {
        let stats = nix::sys::statvfs::statvfs(path)
            .map_err(|error| format!("cannot stat {}: {error}", path.display()))?;
        let free = u64::from(stats.blocks_free()).saturating_mul(stats.fragment_size());
        if tightest.is_none_or(|(_, least)| free < least) {
            tightest = Some((path, free));
        }
    }
    let (path, free) = tightest.expect("at least one filesystem measured");
    let needed = package_size.saturating_add(DISK_RESERVE_BYTES);
    if free < needed {
        return Err(ApplyError::from(format!(
            "UPDATE_DISK_INSUFFICIENT {} has {free} bytes free; need at least {needed} for the package plus reserve",
            path.display()
        )));
    }
    Ok(())
}

/// Recreate staging and finish all fixed-name writes through a no-follow directory descriptor before privileged handoff.
fn stage_release(
    staged_dir: &Path,
    manifest_bytes: &[u8],
    request: &ApplyRequest<'_>,
) -> Result<(), ApplyError> {
    use nix::libc;
    use std::io::Write;
    use std::os::fd::{AsRawFd, FromRawFd};
    use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt, PermissionsExt};
    fs::create_dir_all(request.staging_root)?;
    let _staging_guard = spark_privd::update::acquire_staging_lock(request.staging_root, true)?;
    if let Ok(metadata) = fs::symlink_metadata(staged_dir) {
        if metadata.is_symlink() || !metadata.is_dir() {
            return Err(ApplyError::from(
                "staging directory is not a real directory",
            ));
        }
        fs::remove_dir_all(staged_dir)?;
    }
    // mkdir refuses a pre-existing final component, including a raced symlink.
    fs::DirBuilder::new().mode(0o750).create(staged_dir)?;
    let directory = fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_DIRECTORY)
        .open(staged_dir)?;
    // Set modes through descriptors so umask cannot block helper group access and path races cannot redirect chmod.
    directory.set_permissions(fs::Permissions::from_mode(0o750))?;
    let create = |name: &str| -> Result<fs::File, ApplyError> {
        let name = std::ffi::CString::new(name).expect("fixed staged filename");
        let fd = unsafe {
            libc::openat(
                directory.as_raw_fd(),
                name.as_ptr(),
                libc::O_WRONLY | libc::O_CREAT | libc::O_EXCL | libc::O_NOFOLLOW | libc::O_CLOEXEC,
                0o640,
            )
        };
        if fd < 0 {
            return Err(std::io::Error::last_os_error().into());
        }
        let file = unsafe { fs::File::from_raw_fd(fd) };
        file.set_permissions(fs::Permissions::from_mode(0o640))?;
        Ok(file)
    };
    let mut manifest = create(STAGED_MANIFEST)?;
    manifest.write_all(manifest_bytes)?;
    manifest.sync_all()?;
    for (source, name) in [
        (request.package_path, STAGED_PACKAGE),
        (request.signature_path, STAGED_SIGNATURE),
    ] {
        let mut output = create(name)?;
        std::io::copy(&mut fs::File::open(source)?, &mut output)?;
        output.sync_all()?;
    }
    directory.sync_all()?;
    Ok(())
}

#[cfg(test)]
#[path = "apply/tests.rs"]
mod tests;
