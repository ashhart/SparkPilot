use super::*;

// Resolve service credentials and live-process evidence.

pub(super) fn account_ids(user: &str) -> Result<(u32, u32), StateError> {
    let name = CString::new(user).map_err(|_| StateError::UnknownAccount(user.to_owned()))?;
    // SAFETY: read getpwnam's static-buffer result immediately without retaining its pointer.
    let entry = unsafe { libc::getpwnam(name.as_ptr()) };
    if entry.is_null() {
        return Err(StateError::UnknownAccount(user.to_owned()));
    }
    // SAFETY: checked non-null immediately above.
    let entry = unsafe { *entry };
    Ok((entry.pw_uid, entry.pw_gid))
}

pub(super) fn group_id(group: &str) -> Result<u32, StateError> {
    let name = CString::new(group).map_err(|_| StateError::UnknownAccount(group.to_owned()))?;
    // SAFETY: as `account_ids`.
    let entry = unsafe { libc::getgrnam(name.as_ptr()) };
    if entry.is_null() {
        return Err(StateError::UnknownAccount(group.to_owned()));
    }
    // SAFETY: checked non-null immediately above.
    Ok(unsafe { *entry }.gr_gid)
}

/// Find live processes by procfs uid, excluding exited zombies that hold no descriptors and cannot race state repair.
pub(super) fn process_running_as(uid: u32) -> Option<u32> {
    use std::os::unix::fs::MetadataExt;

    let entries = std::fs::read_dir("/proc").ok()?;
    for entry in entries.flatten() {
        let name = entry.file_name();
        let Some(pid) = name.to_str().and_then(|value| value.parse::<u32>().ok()) else {
            continue;
        };
        let Ok(metadata) = std::fs::metadata(entry.path()) else {
            continue;
        };
        if metadata.uid() != uid || is_zombie(&entry.path()) {
            continue;
        }
        return Some(pid);
    }
    None
}

/// Read process state after the last ')' because comm may contain spaces and parentheses, including fake state characters.
pub(super) fn is_zombie(proc_dir: &Path) -> bool {
    let Ok(stat) = std::fs::read_to_string(proc_dir.join("stat")) else {
        // Unreadable procfs is not proof of a zombie; let the caller recheck a disappearing process.
        return false;
    };
    let Some(after_comm) = stat.rsplit_once(')') else {
        return false;
    };
    after_comm.1.split_whitespace().next() == Some("Z")
}
