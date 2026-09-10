use super::*;

/// What the first-install catalogue seed did.
#[derive(Debug, Clone, Serialize)]
pub struct CatalogueSeedReport {
    pub path: PathBuf,
    pub seeded: bool,
}

pub(super) const BOOTSTRAP_CATALOGUE: &str = "/usr/share/spark-runtime/catalog/bootstrap.json";

pub(super) const LIVE_CATALOGUE_DIR: &str = "/var/lib/spark-runtime/catalogue";

pub(super) const MAX_BOOTSTRAP_CATALOGUE_BYTES: u64 = 32 * 1024 * 1024;

/// Publish a complete signed catalogue by exclusive temporary inode and no-replace hard link; retain regular files and refuse substituted destinations.
pub fn seed_catalogue(
    service_user: &str,
    service_group: &str,
) -> Result<CatalogueSeedReport, StateError> {
    let (uid, _) = account_ids(service_user)?;
    let gid = group_id(service_group)?;
    if let Some(pid) = process_running_as(uid) {
        return Err(StateError::ServiceStillRunning { uid, pid });
    }

    let source = Path::new(BOOTSTRAP_CATALOGUE);
    let bytes = read_regular_file(source, MAX_BOOTSTRAP_CATALOGUE_BYTES)?;

    let var_lib_path = Path::new("/var/lib");
    let var_lib = open_trusted_directory(var_lib_path)?;
    let state_path = var_lib_path.join("spark-runtime");
    let state = open_or_create_child(&var_lib, "spark-runtime", 0o750, &state_path)?;
    set_ownership(&state, uid, gid, &state_path)?;
    set_mode(&state, 0o750, &state_path)?;

    let catalogue_path = state_path.join("catalogue");
    let catalogue = open_or_create_child(&state, "catalogue", 0o750, &catalogue_path)?;
    set_ownership(&catalogue, uid, gid, &catalogue_path)?;
    set_mode(&catalogue, 0o750, &catalogue_path)?;

    let seeded = seed_child_if_absent(
        &catalogue,
        "catalogue.json",
        &bytes,
        0o640,
        uid,
        gid,
        &catalogue_path,
    )?;
    Ok(CatalogueSeedReport {
        path: PathBuf::from(LIVE_CATALOGUE_DIR).join("catalogue.json"),
        seeded,
    })
}

#[allow(clippy::too_many_arguments)]
pub(super) fn seed_child_if_absent(
    parent: &OwnedFd,
    name: &str,
    bytes: &[u8],
    mode: u32,
    uid: u32,
    gid: u32,
    display_parent: &Path,
) -> Result<bool, StateError> {
    let display = display_parent.join(name);
    if inspect_regular_child(parent, name, &display)? {
        return Ok(false);
    }

    let temporary_name = format!(".{name}.seed-{}", uuid::Uuid::new_v4());
    let c_temporary = c_string(Path::new(&temporary_name))?;
    // SAFETY: live parent fd and valid name; an exclusive unpredictable temporary name prevents populating an attacker-selected file.
    let raw = unsafe {
        libc::openat(
            parent.as_raw_fd(),
            c_temporary.as_ptr(),
            libc::O_WRONLY | libc::O_CREAT | libc::O_EXCL | libc::O_NOFOLLOW | libc::O_CLOEXEC,
            mode as libc::c_uint,
        )
    };
    if raw < 0 {
        return Err(classify(
            io::Error::last_os_error(),
            "create",
            &display_parent.join(&temporary_name),
        ));
    }
    // SAFETY: `raw` is a fresh descriptor from `openat`.
    let fd = unsafe { OwnedFd::from_raw_fd(raw) };
    let temporary_display = display_parent.join(&temporary_name);
    if let Err(error) = set_ownership(&fd, uid, gid, &temporary_display) {
        let _ = unlink_child(parent, &temporary_name);
        return Err(error);
    }
    if let Err(error) = set_mode(&fd, mode, &temporary_display) {
        let _ = unlink_child(parent, &temporary_name);
        return Err(error);
    }
    let mut file = std::fs::File::from(fd);
    if let Err(source) = std::io::Write::write_all(&mut file, bytes) {
        let _ = unlink_child(parent, &temporary_name);
        return Err(StateError::Io {
            action: "write",
            path: temporary_display,
            source,
        });
    }
    if let Err(source) = file.sync_all() {
        let _ = unlink_child(parent, &temporary_name);
        return Err(StateError::Io {
            action: "flush",
            path: temporary_display,
            source,
        });
    }
    drop(file);

    let c_name = c_string(Path::new(name))?;
    // SAFETY: live directory fds and valid names let linkat publish the complete inode without replacing a catalogue on Linux or macOS.
    let linked = unsafe {
        libc::linkat(
            parent.as_raw_fd(),
            c_temporary.as_ptr(),
            parent.as_raw_fd(),
            c_name.as_ptr(),
            0,
        )
    };
    let link_error = if linked < 0 {
        Some(io::Error::last_os_error())
    } else {
        None
    };
    let _ = unlink_child(parent, &temporary_name);

    match link_error {
        None => {
            // SAFETY: `parent` is a live directory descriptor.
            if unsafe { libc::fsync(parent.as_raw_fd()) } < 0 {
                return Err(classify(
                    io::Error::last_os_error(),
                    "flush directory",
                    display_parent,
                ));
            }
            Ok(true)
        }
        Some(error) if error.raw_os_error() == Some(libc::EEXIST) => {
            inspect_regular_child(parent, name, &display)?;
            Ok(false)
        }
        Some(error) => Err(classify(error, "publish", &display)),
    }
}
