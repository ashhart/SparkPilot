//! Hold a validated mount source open by descriptor so a directory swapped for a symlink after validation is detected, not mounted.

use std::ffi::CString;
use std::io;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
use std::os::unix::ffi::OsStrExt;
use std::path::{Component, Path, PathBuf};

/// Why a directory could not be pinned or no longer matches its pin.
#[derive(Debug, thiserror::Error)]
pub enum PinError {
    #[error("path is not a plain path beneath its root: {0}")]
    UnsafePath(String),
    #[error("path component is a symbolic link: {0}")]
    Symlink(String),
    #[error("{0}: {1}")]
    Io(String, String),
    #[error("{0} was replaced after validation")]
    Replaced(String),
}

/// A directory opened through a no-follow component walk, with the identity recorded at validation.
pub struct PinnedDirectory {
    _fd: OwnedFd,
    root: PathBuf,
    relative: PathBuf,
    device: u64,
    inode: u64,
}

impl std::fmt::Debug for PinnedDirectory {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("PinnedDirectory")
            .field("path", &self.path())
            .field("device", &self.device)
            .field("inode", &self.inode)
            .finish()
    }
}

fn c_string(path: &Path) -> Result<CString, PinError> {
    CString::new(path.as_os_str().as_bytes())
        .map_err(|_| PinError::UnsafePath(path.display().to_string()))
}

/// Is the named entry a symbolic link (the classification the O_NOFOLLOW refusal cannot express portably)?
fn is_symlink_at(directory: Option<&OwnedFd>, name: &CString) -> bool {
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

/// Open one directory component without following a link in that component.
fn open_directory(
    parent: Option<&OwnedFd>,
    name: &Path,
    display: &Path,
) -> Result<OwnedFd, PinError> {
    let c_name = c_string(name)?;
    let flags = libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC;
    let raw = match parent {
        Some(parent) => unsafe { libc::openat(parent.as_raw_fd(), c_name.as_ptr(), flags) },
        None => unsafe { libc::open(c_name.as_ptr(), flags) },
    };
    if raw < 0 {
        let error = io::Error::last_os_error();
        if matches!(
            error.raw_os_error(),
            Some(libc::ELOOP) | Some(libc::EMLINK) | Some(libc::ENOTDIR)
        ) && is_symlink_at(parent, &c_name)
        {
            return Err(PinError::Symlink(display.display().to_string()));
        }
        return Err(PinError::Io(
            display.display().to_string(),
            error.to_string(),
        ));
    }
    Ok(unsafe { OwnedFd::from_raw_fd(raw) })
}

/// Walk from the root through every relative component, refusing links, and return the leaf with its identity.
#[allow(clippy::unnecessary_cast)]
fn walk(root: &Path, relative: &Path) -> Result<(OwnedFd, u64, u64), PinError> {
    if !root.is_absolute() {
        return Err(PinError::UnsafePath(root.display().to_string()));
    }
    let mut components = Vec::new();
    for component in relative.components() {
        match component {
            Component::Normal(name) if !name.is_empty() => components.push(Path::new(name)),
            _ => return Err(PinError::UnsafePath(relative.display().to_string())),
        }
    }
    if components.is_empty() {
        return Err(PinError::UnsafePath(relative.display().to_string()));
    }
    // The root's own name may not be a link either; only ancestors above the configured root are trusted.
    let mut directory = open_directory(None, root, root)?;
    let mut display = root.to_path_buf();
    for component in components {
        display.push(component);
        directory = open_directory(Some(&directory), component, &display)?;
    }
    let mut status: libc::stat = unsafe { std::mem::zeroed() };
    if unsafe { libc::fstat(directory.as_raw_fd(), &mut status) } < 0 {
        let error = io::Error::last_os_error();
        return Err(PinError::Io(
            display.display().to_string(),
            error.to_string(),
        ));
    }
    if (status.st_mode & libc::S_IFMT) != libc::S_IFDIR {
        return Err(PinError::Io(
            display.display().to_string(),
            "not a directory".into(),
        ));
    }
    // dev_t is i32 on Darwin and u64 on Linux; widen it so the pin compares the same way everywhere.
    Ok((directory, status.st_dev as u64, status.st_ino))
}

impl PinnedDirectory {
    /// Open `root/relative` component by component with O_DIRECTORY|O_NOFOLLOW and keep the leaf descriptor.
    pub fn open(root: &Path, relative: &Path) -> Result<Self, PinError> {
        let (fd, device, inode) = walk(root, relative)?;
        Ok(Self {
            _fd: fd,
            root: root.to_path_buf(),
            relative: relative.to_path_buf(),
            device,
            inode,
        })
    }

    /// The host path a mount source names; the pin proves what that name resolved to when validated.
    pub fn path(&self) -> PathBuf {
        self.root.join(&self.relative)
    }

    /// Re-walk the same name and require it to reach the pinned inode; a swap for a link or another directory fails.
    pub fn verify(&self) -> Result<(), PinError> {
        let (_fd, device, inode) = walk(&self.root, &self.relative)?;
        if device != self.device || inode != self.inode {
            return Err(PinError::Replaced(self.path().display().to_string()));
        }
        Ok(())
    }
}

#[cfg(test)]
#[path = "mount_pin/tests.rs"]
mod tests;
