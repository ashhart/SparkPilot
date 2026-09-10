//! Repair through no-follow component descriptors only after all live service-uid processes stop; see RUNTIME-INVARIANTS.md.

use std::ffi::CString;

use std::io::{self, Read};

use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};

use std::path::{Path, PathBuf};

use serde::Serialize;

use thiserror::Error;

#[derive(Debug, Error)]
pub enum StateError {
    #[error("node authority custody: {0}")]
    Custody(String),
    #[error("{path} is a symbolic link; refusing to follow it")]
    Symlink { path: PathBuf },
    #[error("{path} exists but is not a directory")]
    NotADirectory { path: PathBuf },
    #[error("{path} exists but is not a regular file")]
    NotARegularFile { path: PathBuf },
    #[error("{path} exceeds the {maximum_bytes}-byte installer limit")]
    FileTooLarge { path: PathBuf, maximum_bytes: u64 },
    #[error("{path} is not a path this installer may prepare")]
    UntrustedPath { path: PathBuf },
    #[error("failed to {action} {path}: {source}")]
    Io {
        action: &'static str,
        path: PathBuf,
        #[source]
        source: io::Error,
    },
    #[error("no account named {0:?}")]
    UnknownAccount(String),
    #[error(
        "a process is still running as uid {uid} (pid {pid}); refusing to prepare directories \\
         it could replace underneath us"
    )]
    ServiceStillRunning { uid: u32, pid: u32 },
}

/// Who a directory belongs to.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Owner {
    /// root:root. Nothing the service account can reach.
    Root,
    /// root:service. Readable by the service, writable only by root.
    RootServiceGroup,
    /// service:service.
    Service,
}

/// One directory to create or repair.
#[derive(Debug, Clone, Serialize)]
pub struct DirectorySpec {
    /// Relative to the trusted parent; one component per element.
    pub components: Vec<String>,
    pub mode: u32,
    pub owner: Owner,
}

impl DirectorySpec {
    fn new(components: &[&str], mode: u32, owner: Owner) -> Self {
        Self {
            components: components.iter().map(|part| (*part).to_owned()).collect(),
            mode,
            owner,
        }
    }
}

/// What [`prepare`] did.
#[derive(Debug, Clone, Serialize)]
pub struct StateReport {
    pub prepared: Vec<PathBuf>,
    pub service_uid: u32,
    pub service_gid: u32,
}

/// Resolve only root-owned layout prefixes; open every lower component relative to a held descriptor.
fn layout() -> Vec<(&'static str, Vec<DirectorySpec>)> {
    vec![
        (
            "/etc",
            vec![
                DirectorySpec::new(&["spark-runtime"], 0o750, Owner::RootServiceGroup),
                DirectorySpec::new(&["spark-runtime", "trust"], 0o700, Owner::Root),
            ],
        ),
        (
            "/var/lib",
            vec![
                DirectorySpec::new(&["spark-runtime"], 0o750, Owner::Service),
                DirectorySpec::new(&["spark-runtime", "identity"], 0o700, Owner::Service),
                DirectorySpec::new(&["spark-runtime", "catalogue"], 0o750, Owner::Service),
                DirectorySpec::new(&["spark-runtime", "models"], 0o750, Owner::Service),
                DirectorySpec::new(&["spark-runtime", "projects"], 0o750, Owner::Service),
                // Match systemd's rollback-state ownership/mode during plain dpkg installs that do not run systemd.
                DirectorySpec::new(&["spark-privd"], 0o700, Owner::RootServiceGroup),
            ],
        ),
        (
            "/var/cache",
            vec![
                DirectorySpec::new(&["spark-runtime"], 0o750, Owner::Service),
                DirectorySpec::new(&["spark-runtime", "downloads"], 0o750, Owner::Service),
            ],
        ),
        (
            // Keep upgrade snapshots root-only so the service cannot read or alter rollback state.
            "/var",
            vec![
                DirectorySpec::new(&["backups"], 0o755, Owner::Root),
                DirectorySpec::new(&["backups", "spark-runtime"], 0o700, Owner::Root),
            ],
        ),
    ]
}

/// Idempotently repair state directories without resolving paths controlled by the service account.
pub fn prepare(service_user: &str, service_group: &str) -> Result<StateReport, StateError> {
    let (uid, _) = account_ids(service_user)?;
    let gid = group_id(service_group)?;

    // Refuse live service-uid processes before opening components so they cannot race directory replacement.
    if let Some(pid) = process_running_as(uid) {
        return Err(StateError::ServiceStillRunning { uid, pid });
    }

    let mut prepared = Vec::new();
    for (trusted_parent, specs) in layout() {
        let parent_path = Path::new(trusted_parent);
        let parent = open_trusted_directory(parent_path)?;

        for spec in specs {
            let mut current = parent.try_clone().map_err(|source| StateError::Io {
                action: "duplicate a descriptor for",
                path: parent_path.to_path_buf(),
                source,
            })?;
            let mut walked = parent_path.to_path_buf();

            for (index, component) in spec.components.iter().enumerate() {
                walked.push(component);
                let last = index + 1 == spec.components.len();
                // Earlier specs created intermediate directories with their required modes; apply this spec's mode only to its final component.
                let mode = if last { spec.mode } else { 0o750 };
                current = open_or_create_child(&current, component, mode, &walked)?;
            }

            let (owner_uid, owner_gid) = match spec.owner {
                Owner::Root => (0, 0),
                Owner::RootServiceGroup => (0, gid),
                Owner::Service => (uid, gid),
            };
            set_ownership(&current, owner_uid, owner_gid, &walked)?;
            set_mode(&current, spec.mode, &walked)?;
            prepared.push(walked);
        }
    }

    Ok(StateReport {
        prepared,
        service_uid: uid,
        service_gid: gid,
    })
}

fn classify(error: io::Error, action: &'static str, path: &Path) -> StateError {
    match error.raw_os_error() {
        // After refusal, inspect the object to distinguish symlinks because Linux and Darwin may return ELOOP or ENOTDIR differently.
        Some(libc::ELOOP) | Some(libc::ENOTDIR) => {
            if std::fs::symlink_metadata(path)
                .map(|metadata| metadata.file_type().is_symlink())
                .unwrap_or(false)
            {
                StateError::Symlink {
                    path: path.to_path_buf(),
                }
            } else {
                StateError::NotADirectory {
                    path: path.to_path_buf(),
                }
            }
        }
        _ => StateError::Io {
            action,
            path: path.to_path_buf(),
            source: error,
        },
    }
}

#[cfg(test)]
#[path = "state/tests.rs"]
mod tests;

// Restore database and configuration from retained upgrade snapshots.

/// What [`restore`] put back.
#[derive(Debug, Clone, Serialize)]
pub struct RestoreReport {
    pub restored: Vec<PathBuf>,
    pub removed: Vec<PathBuf>,
}

/// Restore through held no-follow directories, unlink child names and create exclusive replacements; apply ownership by descriptor.
pub fn restore(
    backup: &Path,
    state_dir: &Path,
    conf_dir: &Path,
    service_user: &str,
    service_group: &str,
) -> Result<RestoreReport, StateError> {
    let (uid, _) = account_ids(service_user)?;
    let gid = group_id(service_group)?;
    if let Some(pid) = process_running_as(uid) {
        return Err(StateError::ServiceStillRunning { uid, pid });
    }

    let mut restored = Vec::new();
    let mut removed = Vec::new();

    let state = open_trusted_directory(state_dir)?;
    // Remove old WAL/SHM files because sqlite3 .backup snapshots are self-contained and must not replay the replaced database's log.
    for stale in ["runtime.db-wal", "runtime.db-shm"] {
        if unlink_child(&state, stale)? {
            removed.push(state_dir.join(stale));
        }
    }

    if let Some(bytes) =
        read_backup_member(&backup.join("runtime.db"), MAX_RESTORED_DATABASE_BYTES)?
    {
        write_child(&state, "runtime.db", &bytes, 0o640, uid, gid, state_dir)?;
        restored.push(state_dir.join("runtime.db"));
    }

    if let Some(bytes) = read_backup_member(
        &backup.join("config.toml"),
        MAX_RESTORED_CONFIGURATION_BYTES,
    )? {
        let conf = open_trusted_directory(conf_dir)?;
        write_child(&conf, "config.toml", &bytes, 0o640, 0, gid, conf_dir)?;
        restored.push(conf_dir.join("config.toml"));
    }

    Ok(RestoreReport { restored, removed })
}

/// Backups hold one SQLite snapshot; anything larger than this is not a database this installer wrote.
pub const MAX_RESTORED_DATABASE_BYTES: u64 = 4 * 1024 * 1024 * 1024;
/// A configuration file is hand-written TOML; a megabyte is already absurd.
pub const MAX_RESTORED_CONFIGURATION_BYTES: u64 = 1024 * 1024;

/// Read one optional backup member without following a link and within a size bound; absence is not an error.
fn read_backup_member(path: &Path, maximum_bytes: u64) -> Result<Option<Vec<u8>>, StateError> {
    match std::fs::symlink_metadata(path) {
        Ok(metadata) if metadata.file_type().is_symlink() => {
            return Err(StateError::Symlink {
                path: path.to_path_buf(),
            });
        }
        Ok(_) => {}
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(None),
        Err(source) => {
            return Err(StateError::Io {
                action: "inspect",
                path: path.to_path_buf(),
                source,
            });
        }
    }
    read_regular_file(path, maximum_bytes).map(Some)
}

#[cfg(test)]
#[path = "state/restore_tests.rs"]
mod restore_tests;

#[cfg(test)]
#[path = "state/catalogue_seed_tests.rs"]
mod catalogue_seed_tests;

mod catalogue;
pub use catalogue::{CatalogueSeedReport, seed_catalogue};

mod filesystem;
use filesystem::{
    c_string, inspect_regular_child, open_or_create_child, open_trusted_directory,
    read_regular_file, set_mode, set_ownership, unlink_child, write_child,
};

mod account;
use account::{account_ids, group_id, process_running_as};

pub mod custody;
