use super::*;

// Access filesystem objects relative to held no-follow descriptors.

/// Open only root-controlled prefixes by path and reject a symlink in the final component.
pub(super) fn open_trusted_directory(path: &Path) -> Result<OwnedFd, StateError> {
    let c_path = c_string(path)?;
    // SAFETY: the NUL-terminated path lives through open and the returned descriptor is immediately owned.
    let raw = unsafe {
        libc::open(
            c_path.as_ptr(),
            libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_RDONLY,
        )
    };
    if raw < 0 {
        return Err(classify(io::Error::last_os_error(), "open", path));
    }
    // SAFETY: `raw` is a fresh, valid, owned descriptor.
    Ok(unsafe { OwnedFd::from_raw_fd(raw) })
}

/// Open one child directory, creating it if absent, never following a link.
pub(super) fn open_or_create_child(
    parent: &OwnedFd,
    name: &str,
    mode: u32,
    display: &Path,
) -> Result<OwnedFd, StateError> {
    let c_name = c_string(Path::new(name))?;

    // SAFETY: parent fd and name remain valid; EEXIST is expected on repeated directory preparation.
    let made = unsafe { libc::mkdirat(parent.as_raw_fd(), c_name.as_ptr(), mode as libc::mode_t) };
    if made < 0 {
        let error = io::Error::last_os_error();
        if error.raw_os_error() != Some(libc::EEXIST) {
            return Err(classify(error, "create", display));
        }
    }

    // SAFETY: valid parent fd/name; NOFOLLOW rejects symlinks and DIRECTORY rejects regular-file substitutions.
    let raw = unsafe {
        libc::openat(
            parent.as_raw_fd(),
            c_name.as_ptr(),
            libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_RDONLY,
        )
    };
    if raw < 0 {
        return Err(classify(io::Error::last_os_error(), "open", display));
    }
    // SAFETY: `raw` is a fresh, valid, owned descriptor.
    let fd = unsafe { OwnedFd::from_raw_fd(raw) };

    // Verify directory type through the held descriptor so a renamed path cannot change the checked object.
    let mut status: libc::stat = unsafe { std::mem::zeroed() };
    // SAFETY: `fd` is live and `status` is a valid out-parameter.
    if unsafe { libc::fstat(fd.as_raw_fd(), &mut status) } < 0 {
        return Err(classify(io::Error::last_os_error(), "inspect", display));
    }
    if status.st_mode & libc::S_IFMT != libc::S_IFDIR {
        return Err(StateError::NotADirectory {
            path: display.to_path_buf(),
        });
    }
    Ok(fd)
}

pub(super) fn read_regular_file(path: &Path, maximum_bytes: u64) -> Result<Vec<u8>, StateError> {
    let c_path = c_string(path)?;
    // SAFETY: the path lives through open, its fd is immediately owned, and NOFOLLOW rejects substituted package symlinks.
    let raw = unsafe {
        libc::open(
            c_path.as_ptr(),
            libc::O_RDONLY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
        )
    };
    if raw < 0 {
        return Err(classify(io::Error::last_os_error(), "open", path));
    }
    // SAFETY: `raw` is a fresh descriptor from `open`.
    let fd = unsafe { OwnedFd::from_raw_fd(raw) };
    let mut status: libc::stat = unsafe { std::mem::zeroed() };
    // SAFETY: `fd` is live and `status` is a valid out-parameter.
    if unsafe { libc::fstat(fd.as_raw_fd(), &mut status) } < 0 {
        return Err(classify(io::Error::last_os_error(), "inspect", path));
    }
    if status.st_mode & libc::S_IFMT != libc::S_IFREG {
        return Err(StateError::NotARegularFile {
            path: path.to_path_buf(),
        });
    }
    let length = u64::try_from(status.st_size).unwrap_or(u64::MAX);
    if length > maximum_bytes {
        return Err(StateError::FileTooLarge {
            path: path.to_path_buf(),
            maximum_bytes,
        });
    }

    let mut bytes = Vec::with_capacity(length as usize);
    let file = std::fs::File::from(fd);
    file.take(maximum_bytes + 1)
        .read_to_end(&mut bytes)
        .map_err(|source| StateError::Io {
            action: "read",
            path: path.to_path_buf(),
            source,
        })?;
    if bytes.len() as u64 > maximum_bytes {
        return Err(StateError::FileTooLarge {
            path: path.to_path_buf(),
            maximum_bytes,
        });
    }
    Ok(bytes)
}

pub(super) fn inspect_regular_child(
    parent: &OwnedFd,
    name: &str,
    display: &Path,
) -> Result<bool, StateError> {
    let c_name = c_string(Path::new(name))?;
    let mut status: libc::stat = unsafe { std::mem::zeroed() };
    // SAFETY: valid parent, name and output storage; AT_SYMLINK_NOFOLLOW reports the named object itself.
    if unsafe {
        libc::fstatat(
            parent.as_raw_fd(),
            c_name.as_ptr(),
            &mut status,
            libc::AT_SYMLINK_NOFOLLOW,
        )
    } < 0
    {
        let error = io::Error::last_os_error();
        if error.raw_os_error() == Some(libc::ENOENT) {
            return Ok(false);
        }
        return Err(classify(error, "inspect", display));
    }
    match status.st_mode & libc::S_IFMT {
        libc::S_IFREG => Ok(true),
        libc::S_IFLNK => Err(StateError::Symlink {
            path: display.to_path_buf(),
        }),
        _ => Err(StateError::NotARegularFile {
            path: display.to_path_buf(),
        }),
    }
}

pub(super) fn set_ownership(
    fd: &OwnedFd,
    uid: u32,
    gid: u32,
    display: &Path,
) -> Result<(), StateError> {
    // Skip already-correct ownership so non-root verification succeeds without attempting a privileged no-op change.
    let mut status: libc::stat = unsafe { std::mem::zeroed() };
    // SAFETY: `fd` is live and `status` is a valid out-parameter.
    if unsafe { libc::fstat(fd.as_raw_fd(), &mut status) } == 0
        && status.st_uid == uid
        && status.st_gid == gid
    {
        return Ok(());
    }

    // SAFETY: fchown uses the same live descriptor whose ownership was checked.
    if unsafe { libc::fchown(fd.as_raw_fd(), uid, gid) } < 0 {
        return Err(classify(
            io::Error::last_os_error(),
            "set the owner of",
            display,
        ));
    }
    Ok(())
}

pub(super) fn set_mode(fd: &OwnedFd, mode: u32, display: &Path) -> Result<(), StateError> {
    let mut status: libc::stat = unsafe { std::mem::zeroed() };
    // SAFETY: `fd` is live and `status` is a valid out-parameter.
    if unsafe { libc::fstat(fd.as_raw_fd(), &mut status) } == 0
        && u32::from(status.st_mode) & 0o777 == mode
    {
        return Ok(());
    }
    // SAFETY: `fd` is a live descriptor.
    if unsafe { libc::fchmod(fd.as_raw_fd(), mode as libc::mode_t) } < 0 {
        return Err(classify(
            io::Error::last_os_error(),
            "set the mode of",
            display,
        ));
    }
    Ok(())
}

pub(super) fn c_string(path: &Path) -> Result<CString, StateError> {
    CString::new(path.as_os_str().as_encoded_bytes()).map_err(|_| StateError::UntrustedPath {
        path: path.to_path_buf(),
    })
}

/// Remove one child name with unlinkat; symlinks are removed without being followed.
pub(super) fn unlink_child(parent: &OwnedFd, name: &str) -> Result<bool, StateError> {
    let c_name = c_string(Path::new(name))?;
    // SAFETY: `parent` is a live directory descriptor and `c_name` is valid.
    if unsafe { libc::unlinkat(parent.as_raw_fd(), c_name.as_ptr(), 0) } < 0 {
        let error = io::Error::last_os_error();
        return match error.raw_os_error() {
            Some(libc::ENOENT) => Ok(false),
            _ => Err(StateError::Io {
                action: "remove",
                path: PathBuf::from(name),
                source: error,
            }),
        };
    }
    Ok(true)
}

/// Create and fill an exclusive child file; anything appearing after unlink is a race and must not be overwritten.
#[allow(clippy::too_many_arguments)]
pub(super) fn write_child(
    parent: &OwnedFd,
    name: &str,
    bytes: &[u8],
    mode: u32,
    uid: u32,
    gid: u32,
    display_parent: &Path,
) -> Result<(), StateError> {
    use std::io::Write;

    let display = display_parent.join(name);
    // Remove whatever is there first — including a symlink, by name.
    unlink_child(parent, name)?;

    let c_name = c_string(Path::new(name))?;
    // SAFETY: `parent` is live, `c_name` is valid for the call.
    let raw = unsafe {
        libc::openat(
            parent.as_raw_fd(),
            c_name.as_ptr(),
            libc::O_WRONLY | libc::O_CREAT | libc::O_EXCL | libc::O_NOFOLLOW | libc::O_CLOEXEC,
            mode as libc::c_uint,
        )
    };
    if raw < 0 {
        return Err(classify(io::Error::last_os_error(), "create", &display));
    }
    // SAFETY: `raw` is a fresh owned descriptor.
    let fd = unsafe { OwnedFd::from_raw_fd(raw) };

    set_ownership(&fd, uid, gid, &display)?;
    set_mode(&fd, mode, &display)?;

    let mut file = std::fs::File::from(fd);
    file.write_all(bytes).map_err(|source| StateError::Io {
        action: "write",
        path: display.clone(),
        source,
    })?;
    file.sync_all().map_err(|source| StateError::Io {
        action: "flush",
        path: display,
        source,
    })?;
    Ok(())
}
