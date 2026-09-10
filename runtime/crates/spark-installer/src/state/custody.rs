use super::*;
use spark_core::identity::{FileIdentityStore, NodeIdentity};
use std::fs;
use std::os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt};

pub const INSTALLED_IDENTITY: &str = "/etc/spark-runtime/identity";
const FILES: [&str; 4] = ["identity.key", "identity.json", "node.key", "node.crt"];

#[derive(Debug, Serialize)]
pub struct CustodyReport {
    pub node_id: String,
    pub migrated: bool,
    pub legacy_private_files_removed: bool,
}

fn refusal(message: impl Into<String>) -> StateError {
    StateError::Custody(message.into())
}

fn owned_directory(path: &Path, uid: u32) -> Result<(), StateError> {
    let metadata = fs::symlink_metadata(path).map_err(|e| classify(e, "inspect", path))?;
    if !metadata.is_dir()
        || metadata.file_type().is_symlink()
        || metadata.uid() != uid
        || metadata.mode() & 0o022 != 0
    {
        return Err(refusal(
            "identity vault parent must be an owner-controlled directory",
        ));
    }
    Ok(())
}

fn load_vault(path: &Path, uid: u32) -> Result<NodeIdentity, StateError> {
    owned_directory(path, uid)?;
    if fs::metadata(path)
        .map_err(|e| classify(e, "inspect", path))?
        .mode()
        & 0o777
        != 0o700
    {
        return Err(refusal("identity vault must have mode 0700"));
    }
    for name in FILES {
        let child = path.join(name);
        let meta = fs::symlink_metadata(&child).map_err(|e| classify(e, "inspect", &child))?;
        if !meta.is_file()
            || meta.file_type().is_symlink()
            || meta.uid() != uid
            || meta.nlink() != 1
            || meta.mode() & 0o077 != 0
        {
            return Err(refusal(
                "vault files must be private owner-held regular files",
            ));
        }
    }
    let identity = FileIdentityStore::new(path)
        .load()
        .map_err(|e| refusal(e.to_string()))?
        .ok_or_else(|| refusal("missing node identity"))?;
    sparkd::tls::load_or_create(path).map_err(|e| refusal(e.to_string()))?;
    Ok(identity)
}

pub fn installed_identity() -> Result<NodeIdentity, StateError> {
    if unsafe { libc::geteuid() } != 0 {
        return Err(refusal(
            "root is required to load persistent node authority",
        ));
    }
    owned_directory(Path::new("/etc/spark-runtime"), 0)?;
    load_vault(Path::new(INSTALLED_IDENTITY), 0)
}

pub fn drop_to_service() -> Result<(), StateError> {
    let (uid, _) = account_ids("sparkd")?;
    let gid = group_id("sparkd")?;
    if uid == 0 || gid == 0 {
        return Err(refusal("sparkd must not be root"));
    }
    // SAFETY: the installer is single-threaded and permanently relinquishes root before opening service-owned data.
    if unsafe { libc::setgroups(0, std::ptr::null()) } != 0
        || unsafe { libc::setgid(gid) } != 0
        || unsafe { libc::setuid(uid) } != 0
    {
        return Err(refusal("could not permanently drop installer privileges"));
    }
    if unsafe { libc::geteuid() } != uid || unsafe { libc::getuid() } != uid {
        return Err(refusal("installer privilege drop did not take effect"));
    }
    Ok(())
}

pub fn prepare_identity() -> Result<CustodyReport, StateError> {
    if unsafe { libc::geteuid() } != 0 {
        return Err(refusal("root is required to migrate node authority"));
    }
    let (uid, _) = account_ids("sparkd")?;
    if let Some(pid) = process_running_as(uid) {
        return Err(StateError::ServiceStillRunning { uid, pid });
    }
    let state_parent = open_trusted_directory(Path::new("/var/lib"))?;
    let state = open_or_create_child(
        &state_parent,
        "spark-runtime",
        0o750,
        Path::new("/var/lib/spark-runtime"),
    )?;
    let _identity = open_or_create_child(
        &state,
        "identity",
        0o700,
        Path::new("/var/lib/spark-runtime/identity"),
    )?;
    migrate_at(
        Path::new("/var/lib/spark-runtime/identity"),
        Path::new("/etc/spark-runtime"),
        0,
    )
}

fn migrate_at(legacy: &Path, parent: &Path, owner: u32) -> Result<CustodyReport, StateError> {
    owned_directory(parent, owner)?;
    let vault = parent.join("identity");
    if fs::symlink_metadata(&vault).is_ok() {
        let identity = load_vault(&vault, owner)?;
        return Ok(CustodyReport {
            node_id: identity.node_id().to_string(),
            migrated: false,
            legacy_private_files_removed: false,
        });
    }
    let original = FileIdentityStore::new(legacy)
        .load()
        .map_err(|e| refusal(e.to_string()))?
        .ok_or_else(|| refusal("prepare the legacy identity before migration"))?;
    if ["node.key", "node.crt"]
        .iter()
        .any(|name| fs::symlink_metadata(legacy.join(name)).is_ok())
    {
        sparkd::tls::load_or_create(legacy).map_err(|e| refusal(e.to_string()))?;
    }
    let lock_path = parent.join(".identity-migration.lock");
    let lock = fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(false)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW)
        .open(&lock_path)
        .map_err(|e| classify(e, "lock migration", &lock_path))?;
    // SAFETY: a live descriptor holds the advisory lock until drop, including process death during staging.
    if unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
        return Err(refusal("another identity migration is active"));
    }
    let pending = parent.join(".identity.pending");
    let result = (|| {
        if fs::symlink_metadata(&pending).is_ok() {
            owned_directory(&pending, owner)?;
            fs::remove_dir_all(&pending)
                .map_err(|e| classify(e, "clear incomplete staging", &pending))?;
        }
        fs::create_dir(&pending).map_err(|e| classify(e, "create staging", &pending))?;
        fs::set_permissions(&pending, fs::Permissions::from_mode(0o700))
            .map_err(|e| classify(e, "protect staging", &pending))?;
        for name in FILES {
            let source = legacy.join(name);
            if name.starts_with("node.")
                && fs::symlink_metadata(&source).is_err_and(|e| e.kind() == io::ErrorKind::NotFound)
            {
                continue;
            }
            let bytes = zeroize::Zeroizing::new(read_regular_file(&source, 64 * 1024)?);
            let target = pending.join(name);
            let mut output = fs::OpenOptions::new()
                .write(true)
                .create_new(true)
                .mode(0o600)
                .custom_flags(libc::O_NOFOLLOW)
                .open(&target)
                .map_err(|e| classify(e, "create credential", &target))?;
            use std::io::Write;
            output
                .write_all(&bytes)
                .map_err(|e| classify(e, "write credential", &target))?;
            output
                .sync_all()
                .map_err(|e| classify(e, "sync credential", &target))?;
        }
        sparkd::tls::load_or_create(&pending).map_err(|e| refusal(e.to_string()))?;
        fs::set_permissions(pending.join("node.crt"), fs::Permissions::from_mode(0o600))
            .map_err(|e| classify(e, "protect certificate", &pending))?;
        let protected = load_vault(&pending, owner)?;
        if protected.public != original.public {
            return Err(refusal("migration changed node identity"));
        }
        fs::File::open(&pending)
            .and_then(|f| f.sync_all())
            .map_err(|e| classify(e, "sync staging", &pending))?;
        if fs::symlink_metadata(&vault).is_ok() {
            return Err(refusal("vault appeared during migration"));
        }
        fs::rename(&pending, &vault).map_err(|e| classify(e, "publish identity", &vault))?;
        fs::File::open(parent)
            .and_then(|f| f.sync_all())
            .map_err(|e| classify(e, "sync vault parent", parent))?;
        Ok(CustodyReport {
            node_id: protected.node_id().to_string(),
            migrated: true,
            legacy_private_files_removed: false,
        })
    })();
    drop(lock);
    result
}

pub fn complete_identity_migration() -> Result<CustodyReport, StateError> {
    let identity = installed_identity()?;
    let state_parent = open_trusted_directory(Path::new("/var/lib"))?;
    let state = open_or_create_child(
        &state_parent,
        "spark-runtime",
        0o750,
        Path::new("/var/lib/spark-runtime"),
    )?;
    let legacy = open_or_create_child(
        &state,
        "identity",
        0o700,
        Path::new("/var/lib/spark-runtime/identity"),
    )?;
    for name in ["identity.key", "node.key"] {
        unlink_child(&legacy, name)?;
    }
    fs::File::from(legacy)
        .sync_all()
        .map_err(|e| refusal(e.to_string()))?;
    Ok(CustodyReport {
        node_id: identity.node_id().to_string(),
        migrated: false,
        legacy_private_files_removed: true,
    })
}

pub fn restore_legacy_identity() -> Result<CustodyReport, StateError> {
    let identity = installed_identity()?;
    let (uid, _) = account_ids("sparkd")?;
    let gid = group_id("sparkd")?;
    if let Some(pid) = process_running_as(uid) {
        return Err(StateError::ServiceStillRunning { uid, pid });
    }
    let state_parent = open_trusted_directory(Path::new("/var/lib"))?;
    let state = open_or_create_child(
        &state_parent,
        "spark-runtime",
        0o750,
        Path::new("/var/lib/spark-runtime"),
    )?;
    let legacy_path = Path::new("/var/lib/spark-runtime/identity");
    let legacy = open_or_create_child(&state, "identity", 0o700, legacy_path)?;
    for name in FILES {
        let bytes = zeroize::Zeroizing::new(read_regular_file(
            &Path::new(INSTALLED_IDENTITY).join(name),
            64 * 1024,
        )?);
        write_child(&legacy, name, &bytes, 0o600, uid, gid, legacy_path)?;
    }
    fs::File::from(legacy)
        .sync_all()
        .map_err(|e| refusal(e.to_string()))?;
    Ok(CustodyReport {
        node_id: identity.node_id().to_string(),
        migrated: false,
        legacy_private_files_removed: false,
    })
}

#[cfg(test)]
#[path = "custody_tests.rs"]
mod tests;
