use super::*;

pub(super) struct Files<'a> {
    pub(super) locks: &'a coordination::ProjectLocks,
}

impl Files<'_> {
    /// Enforce revision preconditions through beneath-root, no-follow filesystem operations.
    pub fn file_save(
        &self,
        project: &ProjectView,
        relative: &str,
        bytes: &[u8],
        if_match: &str,
    ) -> Result<String, FileSaveError> {
        validate_project_file_path(relative).map_err(FileSaveError::Failure)?;
        let lock = self.locks.lock_for(project.id);
        let _guard = lock.lock();
        let root = &project.root_path;
        let (current_content, current) = match crate::beneath::read_beneath(root, relative) {
            Ok(existing) => {
                let revision = revision_of(&existing);
                (existing, revision)
            }
            // A refused symlink must not be treated as an empty file eligible for overwrite.
            Err(crate::beneath::BeneathError::NotFound(_)) => {
                (Vec::new(), REVISION_EMPTY_HEX.to_owned())
            }
            Err(error) => return Err(FileSaveError::Failure(file_error(error))),
        };
        if if_match != current {
            return Err(FileSaveError::Conflict {
                current_revision: current,
                current_content,
            });
        }
        if let Some((parent, _)) = relative.rsplit_once('/') {
            crate::beneath::create_dir_all_beneath(root, parent)
                .map_err(|error| FileSaveError::Failure(file_error(error)))?;
        }
        crate::beneath::write_beneath(root, relative, bytes)
            .map_err(|error| FileSaveError::Failure(file_error(error)))?;
        Ok(revision_of(bytes))
    }

    pub fn file_read(&self, project: &ProjectView, relative: &str) -> Result<Vec<u8>, String> {
        validate_project_file_path(relative)?;
        crate::beneath::read_beneath(&project.root_path, relative).map_err(file_error)
    }

    pub fn file_list(&self, project: &ProjectView) -> Result<Vec<FileEntry>, String> {
        const MAX_DEPTH: usize = 12;
        const MAX_ENTRIES: usize = 5_000;
        const MAX_EDITABLE_BYTES: u64 = 8 * 1024 * 1024;
        let listed = crate::beneath::list_beneath(&project.root_path, MAX_DEPTH, MAX_ENTRIES)
            .map_err(file_error)?;
        let mut entries = Vec::with_capacity(listed.len());
        for entry in listed {
            if entry.size_bytes > MAX_EDITABLE_BYTES {
                // Large binaries are not part of the editing surface.
                continue;
            }
            let bytes = match crate::beneath::read_beneath(&project.root_path, &entry.relative_path)
            {
                Ok(bytes) => bytes,
                // Omit files that disappear or become unsafe between listing and reading.
                Err(_) => continue,
            };
            entries.push(FileEntry {
                path: entry.relative_path,
                revision: revision_of(&bytes),
                size_bytes: entry.size_bytes,
            });
        }
        Ok(entries)
    }
}

/// Report symlink refusals as unsafe paths, preserving their distinction from missing files.
fn file_error(error: crate::beneath::BeneathError) -> String {
    use crate::beneath::BeneathError;
    match error {
        BeneathError::UnsafePath(detail) => format!("path traversal rejected: {detail}"),
        BeneathError::Symlink(detail) => {
            format!("path traversal rejected: symbolic link is not followed: {detail}")
        }
        BeneathError::NotFound(detail) => format!("FILE_NOT_FOUND:{detail}"),
        BeneathError::Io(detail) => format!("File could not be accessed: {detail}"),
    }
}

/// Refuse Git control paths case-insensitively, including on macOS filesystems.
fn validate_project_file_path(relative: &str) -> Result<(), String> {
    if relative.split('/').any(|part| {
        part.eq_ignore_ascii_case(".git") || part.starts_with(".spark-") || part.starts_with(".g-")
    }) {
        return Err("path traversal rejected: Git control data is not a project file".into());
    }
    Ok(())
}

/// Revision of a file = sha256 of its content (content-addressed).
pub fn revision_of(bytes: &[u8]) -> String {
    hex::encode(sha2::Sha256::digest(bytes))
}
