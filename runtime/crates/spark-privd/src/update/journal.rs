use super::*;

pub(super) struct UpdateJournal<'a> {
    pub(super) state_root: &'a Path,
    pub(super) privileged_uid: u32,
}

impl UpdateJournal<'_> {
    /// Read only root-owned evidence that the service account cannot replace through the protocol.
    pub(super) fn update_status(
        &self,
        release_id: &str,
    ) -> Result<Option<RuntimeUpdateStatus>, UpdateError> {
        validate_release_id(release_id)?;
        if self.current_release_id()?.as_deref() == Some(release_id) {
            return Ok(Some(RuntimeUpdateStatus::Completed {
                outcome: UpdateOutcome::AlreadyCommitted {
                    release_id: release_id.to_owned(),
                },
            }));
        }
        let path = self
            .state_root
            .join(UPDATE_STATUS_DIRECTORY)
            .join(format!("{release_id}.json"));
        let file = match fs::OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NOFOLLOW)
            .open(&path)
        {
            Ok(file) => file,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                return Ok(self
                    .scheduled_release_id()?
                    .filter(|scheduled| scheduled == release_id)
                    .map(|release_id| RuntimeUpdateStatus::Scheduled { release_id }));
            }
            Err(error) => return Err(error.into()),
        };
        let metadata = file.metadata()?;
        if !metadata.is_file()
            || metadata.uid() != self.privileged_uid
            || metadata.permissions().mode() & 0o077 != 0
            || metadata.len() > MAX_UPDATE_STATUS_BYTES
        {
            return Err(UpdateError::refused(
                "UPDATE_STATE_INVALID update outcome is not a private privileged-owned file",
            ));
        }
        let mut bytes = Vec::new();
        file.take(MAX_UPDATE_STATUS_BYTES + 1)
            .read_to_end(&mut bytes)?;
        if bytes.len() as u64 > MAX_UPDATE_STATUS_BYTES {
            return Err(UpdateError::refused(
                "UPDATE_STATE_INVALID update outcome exceeds its size limit",
            ));
        }
        let status = serde_json::from_slice::<RuntimeUpdateStatus>(&bytes).map_err(|_| {
            UpdateError::refused("UPDATE_STATE_INVALID update outcome is malformed")
        })?;
        Ok(Some(status))
    }

    pub(super) fn ensure_state_root(&self) -> Result<(), UpdateError> {
        fs::create_dir_all(self.state_root)?;
        let meta = fs::symlink_metadata(self.state_root)?;
        if meta.file_type().is_symlink() || !meta.is_dir() || meta.uid() != self.privileged_uid {
            return Err(UpdateError::refused(
                "UPDATE_STATE_INVALID update state root is not a privileged-owned directory",
            ));
        }
        fs::set_permissions(self.state_root, fs::Permissions::from_mode(0o700))?;
        Ok(())
    }

    pub(super) fn record_update_status(
        &self,
        status: &RuntimeUpdateStatus,
    ) -> Result<(), UpdateError> {
        let release_id = match status {
            RuntimeUpdateStatus::Scheduled { release_id }
            | RuntimeUpdateStatus::Failed { release_id, .. } => release_id,
            RuntimeUpdateStatus::Completed { outcome } => match outcome {
                UpdateOutcome::Scheduled { release_id }
                | UpdateOutcome::Committed { release_id, .. }
                | UpdateOutcome::AlreadyCommitted { release_id }
                | UpdateOutcome::RolledBack { release_id, .. }
                | UpdateOutcome::DataRestoredPackageManual { release_id, .. } => release_id,
            },
        };
        validate_release_id(release_id)?;
        self.ensure_state_root()?;
        let directory = self.state_root.join(UPDATE_STATUS_DIRECTORY);
        match fs::symlink_metadata(&directory) {
            Ok(metadata)
                if metadata.is_dir()
                    && !metadata.file_type().is_symlink()
                    && metadata.uid() == self.privileged_uid => {}
            Ok(_) => {
                return Err(UpdateError::refused(
                    "UPDATE_STATE_INVALID update outcome directory is not privileged-owned",
                ));
            }
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                fs::create_dir(&directory)?;
            }
            Err(error) => return Err(error.into()),
        }
        fs::set_permissions(&directory, fs::Permissions::from_mode(0o700))?;
        let bytes = serde_json::to_vec(status)
            .map_err(|error| UpdateError::Failure(format!("UPDATE_STATE_INVALID {error}")))?;
        if bytes.len() as u64 > MAX_UPDATE_STATUS_BYTES {
            return Err(UpdateError::refused(
                "UPDATE_STATE_INVALID update outcome exceeds its size limit",
            ));
        }
        let destination = directory.join(format!("{release_id}.json"));
        let temporary = directory.join(format!(".{release_id}.{}.part", uuid::Uuid::new_v4()));
        let mut file = fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW)
            .open(&temporary)?;
        file.write_all(&bytes)?;
        file.sync_all()?;
        fs::rename(&temporary, &destination)?;
        fs::OpenOptions::new()
            .read(true)
            .open(&directory)?
            .sync_all()?;
        Ok(())
    }

    /// Return true only when creating a new handoff marker, false for a matching retry.
    pub(super) fn record_scheduled_release(&self, release_id: &str) -> Result<bool, UpdateError> {
        self.ensure_state_root()?;
        let marker = self.state_root.join(SCHEDULED_RELEASE);
        let mut options = fs::OpenOptions::new();
        options
            .write(true)
            .create_new(true)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW);
        match options.open(&marker) {
            Ok(mut file) => {
                file.write_all(format!("{release_id}\n").as_bytes())?;
                file.sync_all()?;
                Ok(true)
            }
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {
                match self.scheduled_release_id()? {
                    Some(existing) if existing == release_id => Ok(false),
                    Some(existing) => Err(UpdateError::refused(format!(
                        "UPDATE_ALREADY_SCHEDULED {existing} must finish before {release_id}"
                    ))),
                    None => Err(UpdateError::refused(
                        "UPDATE_STATE_INVALID scheduled marker disappeared during hand-off",
                    )),
                }
            }
            Err(error) => Err(error.into()),
        }
    }

    pub(super) fn scheduled_release_id(&self) -> Result<Option<String>, UpdateError> {
        let marker = self.state_root.join(SCHEDULED_RELEASE);
        let meta = match fs::symlink_metadata(&marker) {
            Ok(meta) => meta,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Err(error) => return Err(error.into()),
        };
        if meta.file_type().is_symlink()
            || !meta.is_file()
            || meta.uid() != self.privileged_uid
            || meta.permissions().mode() & 0o077 != 0
        {
            return Err(UpdateError::refused(
                "UPDATE_STATE_INVALID scheduled marker is not a private privileged-owned file",
            ));
        }
        let release_id = fs::read_to_string(&marker)?.trim().to_owned();
        validate_release_id(&release_id)?;
        Ok(Some(release_id))
    }

    pub(super) fn clear_scheduled_release(&self, release_id: &str) -> Result<(), UpdateError> {
        if self.scheduled_release_id()?.as_deref() == Some(release_id) {
            fs::remove_file(self.state_root.join(SCHEDULED_RELEASE))?;
        }
        Ok(())
    }

    pub(super) fn current_release_id(&self) -> Result<Option<String>, UpdateError> {
        let current = self.state_root.join("current-release-id");
        match fs::read_to_string(&current) {
            Ok(content) => Ok(Some(content.trim().to_owned())),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
            Err(error) => Err(error.into()),
        }
    }
}
