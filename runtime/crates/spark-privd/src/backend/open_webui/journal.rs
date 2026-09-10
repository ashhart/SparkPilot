use super::*;

pub(super) struct OwnedJournal<'a> {
    pub(super) open_webui_root: &'a Path,
}

impl OwnedJournal<'_> {
    pub(super) fn webui_root(&self) -> Result<(), BackendError> {
        // Use systemd's root-owned StateDirectory, never sparkd's writable services directory.
        let parent = self.open_webui_root.parent().ok_or_else(ownership_error)?;
        let metadata = fs::symlink_metadata(parent)?;
        if !metadata.is_dir()
            || metadata.file_type().is_symlink()
            || metadata.uid() != unsafe { libc::geteuid() }
            || metadata.mode() & 0o022 != 0
        {
            return Err(ownership_error());
        }
        match fs::symlink_metadata(self.open_webui_root) {
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                fs::DirBuilder::new()
                    .mode(0o700)
                    .create(self.open_webui_root)?;
            }
            Err(error) => return Err(error.into()),
            Ok(_) => {}
        }
        private_metadata(self.open_webui_root, true)?;
        Ok(())
    }

    pub(super) fn webui_write(&self, name: &str, bytes: &[u8]) -> Result<(), BackendError> {
        self.webui_root()?;
        let temporary = self
            .open_webui_root
            .join(format!(".{}.tmp", uuid::Uuid::new_v4()));
        let result = (|| {
            let mut file = OpenOptions::new()
                .write(true)
                .create_new(true)
                .mode(0o600)
                .custom_flags(libc::O_NOFOLLOW)
                .open(&temporary)?;
            file.write_all(bytes)?;
            file.sync_all()?;
            fs::rename(&temporary, self.open_webui_root.join(name))?;
            fs::File::open(self.open_webui_root)?.sync_all()?;
            Ok(())
        })();
        if result.is_err() {
            let _ = fs::remove_file(temporary);
        }
        result
    }

    pub(super) fn webui_save(&self, journal: &Journal) -> Result<(), BackendError> {
        self.webui_write(
            JOURNAL,
            &serde_json::to_vec(journal).map_err(|_| ownership_error())?,
        )
    }

    pub(super) fn webui_load(&self) -> Result<Option<Journal>, BackendError> {
        self.webui_root()?;
        let path = self.open_webui_root.join(JOURNAL);
        match fs::symlink_metadata(&path) {
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Err(error) => return Err(error.into()),
            Ok(_) => {}
        }
        private_metadata(&path, false)?;
        let mut file = OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NOFOLLOW)
            .open(path)?;
        let mut bytes = Vec::new();
        Read::by_ref(&mut file)
            .take(65_537)
            .read_to_end(&mut bytes)?;
        if bytes.len() > 65_536 {
            return Err(ownership_error());
        }
        let journal: Journal = serde_json::from_slice(&bytes).map_err(|_| ownership_error())?;
        if journal.version != 1
            || !crate::protocol::valid_open_webui_port(journal.port)
            || (journal.adopted
                && (journal.volume.is_some()
                    || journal.previous.is_some()
                    || journal.erase_data
                    || journal.phase != Phase::Ready))
            || journal.pending_create
            || journal
                .current
                .iter()
                .chain(journal.previous.iter())
                .any(|container| {
                    !valid_id(&container.id)
                        || if journal.adopted {
                            !adoption::is_open_webui_image(&container.image)
                        } else {
                            !valid_open_webui_image(&container.image)
                        }
                })
        {
            return Err(ownership_error());
        }
        Ok(Some(journal))
    }
}
