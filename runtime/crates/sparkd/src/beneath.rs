//! Walk beneath an opened root with per-component O_NOFOLLOW checks so symlinks and rename races cannot redirect access.

use std::ffi::CString;
use std::io;
use std::os::fd::{AsRawFd, BorrowedFd, FromRawFd, OwnedFd};
use std::os::unix::ffi::OsStrExt;
use std::path::{Component, Path};

/// Why a beneath-root access was refused.
#[derive(Debug, thiserror::Error, PartialEq, Eq)]
pub enum BeneathError {
    /// The relative path was rejected before any syscall.
    #[error("path is not a safe relative path: {0}")]
    UnsafePath(String),
    /// Report a refused symlink distinctly from a missing file.
    #[error("path component is a symbolic link: {0}")]
    Symlink(String),
    /// Only ENOENT may be treated as a file that can be created.
    #[error("{0}")]
    NotFound(String),
    /// Filesystem failure such as missing paths, permissions or unexpected file type.
    #[error("{0}")]
    Io(String),
}

impl BeneathError {
    fn io(error: io::Error) -> Self {
        if error.kind() == io::ErrorKind::NotFound {
            BeneathError::NotFound(error.to_string())
        } else {
            BeneathError::Io(error.to_string())
        }
    }
}

/// Reject absolute paths, dot components, empty segments, NULs and non-name components.
pub fn safe_components(relative: &str) -> Result<Vec<String>, BeneathError> {
    // Check absoluteness before trimming so host paths cannot become accepted relative paths.
    if relative.starts_with('/') {
        return Err(BeneathError::UnsafePath(relative.to_owned()));
    }
    let trimmed = relative.trim_end_matches('/');
    if trimmed.is_empty() {
        return Err(BeneathError::UnsafePath("empty path".into()));
    }
    if relative.contains('\0') {
        return Err(BeneathError::UnsafePath("path contains NUL".into()));
    }
    if relative.len() > 4096 {
        return Err(BeneathError::UnsafePath("path is too long".into()));
    }
    let path = Path::new(trimmed);
    if path.is_absolute() {
        return Err(BeneathError::UnsafePath(relative.to_owned()));
    }
    // Reject raw empty and dot segments before Path::components normalizes alternate spellings.
    if trimmed
        .split('/')
        .any(|segment| segment.is_empty() || segment == "." || segment == "..")
    {
        return Err(BeneathError::UnsafePath(relative.to_owned()));
    }
    let mut components = Vec::new();
    for component in path.components() {
        match component {
            Component::Normal(name) => {
                let name = name
                    .to_str()
                    .ok_or_else(|| BeneathError::UnsafePath(relative.to_owned()))?;
                if name.is_empty() || name == "." || name == ".." {
                    return Err(BeneathError::UnsafePath(relative.to_owned()));
                }
                components.push(name.to_owned());
            }
            _ => return Err(BeneathError::UnsafePath(relative.to_owned())),
        }
    }
    if components.is_empty() {
        return Err(BeneathError::UnsafePath(relative.to_owned()));
    }
    Ok(components)
}

fn openat(
    directory: Option<BorrowedFd<'_>>,
    name: &str,
    flags: libc::c_int,
    mode: libc::mode_t,
) -> Result<OwnedFd, BeneathError> {
    let name = CString::new(name).map_err(|_| BeneathError::UnsafePath(name.to_owned()))?;
    let raw = match directory {
        Some(directory) => unsafe {
            libc::openat(
                directory.as_raw_fd(),
                name.as_ptr(),
                flags,
                mode as libc::c_uint,
            )
        },
        None => unsafe { libc::open(name.as_ptr(), flags, mode as libc::c_uint) },
    };
    if raw < 0 {
        let error = io::Error::last_os_error();
        // Classify symlinks after kernel refusal because Linux and Darwin report different O_NOFOLLOW errors.
        if matches!(
            error.raw_os_error(),
            Some(libc::ELOOP) | Some(libc::EMLINK) | Some(libc::ENOTDIR)
        ) && is_symlink_at(directory, &name)
        {
            return Err(BeneathError::Symlink(name.to_string_lossy().into_owned()));
        }
        return Err(BeneathError::io(error));
    }
    Ok(unsafe { OwnedFd::from_raw_fd(raw) })
}

/// Is `name` inside `directory` a symbolic link?
fn is_symlink_at(directory: Option<BorrowedFd<'_>>, name: &CString) -> bool {
    let mut status: libc::stat = unsafe { std::mem::zeroed() };
    let result = match directory {
        Some(directory) => unsafe {
            libc::fstatat(
                directory.as_raw_fd(),
                name.as_ptr(),
                &mut status,
                libc::AT_SYMLINK_NOFOLLOW,
            )
        },
        None => unsafe { libc::lstat(name.as_ptr(), &mut status) },
    };
    result == 0 && (status.st_mode & libc::S_IFMT) == libc::S_IFLNK
}

/// Open the runtime-owned root normally and refuse symlinks beneath its descriptor.
pub fn open_root(root: &Path) -> Result<OwnedFd, BeneathError> {
    let name = CString::new(root.as_os_str().as_bytes())
        .map_err(|_| BeneathError::UnsafePath(root.display().to_string()))?;
    let raw = unsafe { libc::open(name.as_ptr(), libc::O_RDONLY | libc::O_DIRECTORY, 0) };
    if raw < 0 {
        return Err(BeneathError::io(io::Error::last_os_error()));
    }
    Ok(unsafe { OwnedFd::from_raw_fd(raw) })
}

/// Return the opened parent descriptor and final component after walking all ancestors.
fn walk_parent(root: &Path, relative: &str) -> Result<(OwnedFd, String), BeneathError> {
    let mut components = safe_components(relative)?;
    let last = components.pop().expect("safe_components is never empty");
    let mut directory = open_root(root)?;
    for component in components {
        directory = openat(
            Some(directory.as_fd_borrowed()),
            &component,
            libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW,
            0,
        )?;
    }
    Ok((directory, last))
}

trait AsFdBorrowed {
    fn as_fd_borrowed(&self) -> BorrowedFd<'_>;
}

impl AsFdBorrowed for OwnedFd {
    fn as_fd_borrowed(&self) -> BorrowedFd<'_> {
        unsafe { BorrowedFd::borrow_raw(self.as_raw_fd()) }
    }
}

/// Read a regular file beneath `root`, following no symlink at any depth.
pub fn read_beneath(root: &Path, relative: &str) -> Result<Vec<u8>, BeneathError> {
    read_beneath_bounded(root, relative, usize::MAX)
}

/// Read at most limit plus one byte to distinguish exact-size files from oversized files without full allocation.
pub fn read_beneath_bounded(
    root: &Path,
    relative: &str,
    limit: usize,
) -> Result<Vec<u8>, BeneathError> {
    let (parent, name) = walk_parent(root, relative)?;
    let file = openat(
        Some(parent.as_fd_borrowed()),
        &name,
        libc::O_RDONLY | libc::O_NOFOLLOW | libc::O_NONBLOCK,
        0,
    )?;
    let mut file = std::fs::File::from(file);
    // Serve only regular files so FIFOs cannot block and devices cannot provide arbitrary data.
    let metadata = file.metadata().map_err(BeneathError::io)?;
    if !metadata.is_file() {
        return Err(BeneathError::UnsafePath(format!(
            "{relative} is not a regular file"
        )));
    }
    use std::io::Read as _;
    let capacity = metadata.len().min(limit as u64).min(8 * 1024 * 1024) as usize;
    let mut bytes = Vec::with_capacity(capacity);
    file.by_ref()
        .take(limit.saturating_add(1) as u64)
        .read_to_end(&mut bytes)
        .map_err(BeneathError::io)?;
    if bytes.len() > limit {
        return Err(BeneathError::UnsafePath(format!(
            "{relative} exceeds the {limit}-byte read limit"
        )));
    }
    Ok(bytes)
}

/// Metadata of a file beneath `root` without following links.
pub fn metadata_beneath(root: &Path, relative: &str) -> Result<std::fs::Metadata, BeneathError> {
    let (parent, name) = walk_parent(root, relative)?;
    let file = openat(
        Some(parent.as_fd_borrowed()),
        &name,
        libc::O_RDONLY | libc::O_NOFOLLOW | libc::O_NONBLOCK,
        0,
    )?;
    std::fs::File::from(file)
        .metadata()
        .map_err(BeneathError::io)
}

/// Create and rename through the same parent descriptor so concurrent symlinks cannot redirect atomic writes.
pub fn write_beneath(root: &Path, relative: &str, bytes: &[u8]) -> Result<(), BeneathError> {
    write_with_mode_beneath(root, relative, bytes, 0o600)
}

/// Atomically publish an executable without following a workspace symlink.
pub fn write_executable_beneath(
    root: &Path,
    relative: &str,
    bytes: &[u8],
) -> Result<(), BeneathError> {
    write_with_mode_beneath(root, relative, bytes, 0o700)
}

fn write_with_mode_beneath(
    root: &Path,
    relative: &str,
    bytes: &[u8],
    mode: libc::mode_t,
) -> Result<(), BeneathError> {
    let (parent, name) = walk_parent(root, relative)?;
    let temporary = format!(".spark-tmp-{}", uuid::Uuid::new_v4().simple());
    {
        let file = openat(
            Some(parent.as_fd_borrowed()),
            &temporary,
            libc::O_WRONLY | libc::O_CREAT | libc::O_EXCL | libc::O_NOFOLLOW,
            mode,
        )?;
        let mut file = std::fs::File::from(file);
        use std::io::Write as _;
        file.write_all(bytes).map_err(BeneathError::io)?;
        file.sync_all().map_err(BeneathError::io)?;
    }
    let from =
        CString::new(temporary.clone()).map_err(|_| BeneathError::UnsafePath(temporary.clone()))?;
    let to = CString::new(name.clone()).map_err(|_| BeneathError::UnsafePath(name))?;
    let result = unsafe {
        libc::renameat(
            parent.as_raw_fd(),
            from.as_ptr(),
            parent.as_raw_fd(),
            to.as_ptr(),
        )
    };
    if result < 0 {
        let error = io::Error::last_os_error();
        let unlink = CString::new(temporary).ok();
        if let Some(unlink) = unlink {
            unsafe { libc::unlinkat(parent.as_raw_fd(), unlink.as_ptr(), 0) };
        }
        return Err(BeneathError::io(error));
    }
    Ok(())
}

/// Remove one file beneath `root` without following a link in any component.
pub fn remove_file_beneath(root: &Path, relative: &str) -> Result<(), BeneathError> {
    let (parent, name) = walk_parent(root, relative)?;
    let name = CString::new(name.clone()).map_err(|_| BeneathError::UnsafePath(name))?;
    let result = unsafe { libc::unlinkat(parent.as_raw_fd(), name.as_ptr(), 0) };
    if result < 0 {
        return Err(BeneathError::io(io::Error::last_os_error()));
    }
    Ok(())
}

/// Create relative directories beneath root without traversing symlinks.
pub fn create_dir_all_beneath(root: &Path, relative: &str) -> Result<(), BeneathError> {
    let components = safe_components(relative)?;
    let mut directory = open_root(root)?;
    for component in components {
        let name = CString::new(component.clone())
            .map_err(|_| BeneathError::UnsafePath(component.clone()))?;
        let made = unsafe { libc::mkdirat(directory.as_raw_fd(), name.as_ptr(), 0o750) };
        if made < 0 {
            let error = io::Error::last_os_error();
            if error.raw_os_error() != Some(libc::EEXIST) {
                return Err(BeneathError::io(error));
            }
        }
        directory = openat(
            Some(directory.as_fd_borrowed()),
            &component,
            libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW,
            0,
        )?;
    }
    Ok(())
}

/// One entry from a beneath-root directory listing.
#[derive(Debug, Clone)]
pub struct Entry {
    pub relative_path: String,
    pub size_bytes: u64,
    pub is_directory: bool,
}

/// List regular files without following symlinked directories into the host filesystem.
pub fn list_beneath(
    root: &Path,
    max_depth: usize,
    max_entries: usize,
) -> Result<Vec<Entry>, BeneathError> {
    let mut entries = Vec::new();
    let mut queue = vec![(String::new(), 0usize)];
    while let Some((prefix, depth)) = queue.pop() {
        if depth > max_depth || entries.len() >= max_entries {
            continue;
        }
        let directory = if prefix.is_empty() {
            open_root(root)?
        } else {
            let (parent, name) = walk_parent(root, &prefix)?;
            openat(
                Some(parent.as_fd_borrowed()),
                &name,
                libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW,
                0,
            )?
        };
        // Duplicate the directory descriptor because the directory stream takes ownership.
        let duplicate = unsafe { libc::dup(directory.as_raw_fd()) };
        if duplicate < 0 {
            return Err(BeneathError::io(io::Error::last_os_error()));
        }
        let listing_path = if prefix.is_empty() {
            root.to_path_buf()
        } else {
            root.join(&prefix)
        };
        unsafe { libc::close(duplicate) };
        let listing = std::fs::read_dir(&listing_path).map_err(BeneathError::io)?;
        for entry in listing {
            let entry = entry.map_err(BeneathError::io)?;
            let name = entry.file_name();
            let Some(name) = name.to_str() else { continue };
            if name == ".git"
                || name == ".spark"
                || name.starts_with(".spark-")
                || name.starts_with(".g-")
            {
                continue;
            }
            let relative = if prefix.is_empty() {
                name.to_owned()
            } else {
                format!("{prefix}/{name}")
            };
            // Inspect entries themselves so symlinks remain classified as links.
            let metadata = entry.metadata().map_err(BeneathError::io)?;
            if metadata.file_type().is_symlink() {
                continue;
            }
            if metadata.is_dir() {
                queue.push((relative, depth + 1));
                continue;
            }
            if !metadata.is_file() {
                continue;
            }
            entries.push(Entry {
                relative_path: relative,
                size_bytes: metadata.len(),
                is_directory: false,
            });
            if entries.len() >= max_entries {
                break;
            }
        }
    }
    entries.sort_by(|a, b| a.relative_path.cmp(&b.relative_path));
    Ok(entries)
}

#[cfg(test)]
#[path = "beneath/tests.rs"]
mod tests;

/// Bind through a directory descriptor on Linux: long worktree paths and rename races cannot redirect a gateway.
pub fn bind_unix_listener_beneath(
    root: &Path,
    relative: &str,
) -> Result<std::os::unix::net::UnixListener, BeneathError> {
    let (parent, name) = walk_parent(root, relative)?;
    #[cfg(target_os = "linux")]
    let socket_path =
        std::path::PathBuf::from(format!("/proc/self/fd/{}/{}", parent.as_raw_fd(), name));
    #[cfg(not(target_os = "linux"))]
    let socket_path = {
        let _ = (&parent, &name);
        root.join(relative)
    };
    let listener = std::os::unix::net::UnixListener::bind(socket_path).map_err(BeneathError::io)?;
    listener.set_nonblocking(true).map_err(BeneathError::io)?;
    Ok(listener)
}
