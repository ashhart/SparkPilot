use super::*;

#[derive(serde::Serialize, serde::Deserialize)]
pub(super) struct NetworkRollbackJournal {
    pub(super) version: u32,
    pub(super) pending: HashMap<uuid::Uuid, PendingNetworkRollback>,
}

#[derive(Clone)]
pub(super) struct NetworkRollbackStore {
    pub(super) directory: PathBuf,
    pub(super) owner_uid: u32,
}

pub(super) fn journal_path(store: &NetworkRollbackStore) -> PathBuf {
    store.directory.join(NETWORK_ROLLBACK_JOURNAL_FILE)
}

pub(super) fn invalid_journal(message: impl Into<String>) -> BackendError {
    BackendError::Failure(format!(
        "invalid network rollback journal: {}",
        message.into()
    ))
}

pub(super) fn validate_journal_parent(store: &NetworkRollbackStore) -> Result<(), BackendError> {
    let parent = store
        .directory
        .parent()
        .ok_or_else(|| invalid_journal("journal directory has no parent"))?;
    let metadata = fs::symlink_metadata(parent)?;
    if metadata.file_type().is_symlink() || !metadata.is_dir() {
        return Err(invalid_journal("journal parent is not a real directory"));
    }
    if metadata.uid() != store.owner_uid || metadata.mode() & 0o022 != 0 {
        return Err(invalid_journal(
            "journal parent has unsafe ownership or permissions",
        ));
    }
    Ok(())
}

pub(super) fn validate_journal_directory(store: &NetworkRollbackStore) -> Result<(), BackendError> {
    let metadata = fs::symlink_metadata(&store.directory)?;
    if metadata.file_type().is_symlink() || !metadata.is_dir() {
        return Err(invalid_journal("journal path is not a real directory"));
    }
    if metadata.uid() != store.owner_uid || metadata.mode() & 0o077 != 0 {
        return Err(invalid_journal(
            "journal directory has unsafe ownership or permissions",
        ));
    }
    Ok(())
}

pub(super) fn ensure_journal_directory(store: &NetworkRollbackStore) -> Result<(), BackendError> {
    validate_journal_parent(store)?;
    match fs::symlink_metadata(&store.directory) {
        Ok(_) => validate_journal_directory(store),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            fs::DirBuilder::new().mode(0o700).create(&store.directory)?;
            let parent = store
                .directory
                .parent()
                .ok_or_else(|| invalid_journal("journal directory has no parent"))?;
            OpenOptions::new()
                .read(true)
                .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC)
                .open(parent)?
                .sync_all()?;
            validate_journal_directory(store)
        }
        Err(error) => Err(error.into()),
    }
}

pub(super) fn validate_journal_file(
    metadata: &fs::Metadata,
    store: &NetworkRollbackStore,
) -> Result<(), BackendError> {
    if metadata.file_type().is_symlink() || !metadata.is_file() {
        return Err(invalid_journal("journal path is not a regular file"));
    }
    if metadata.uid() != store.owner_uid || metadata.mode() & 0o077 != 0 {
        return Err(invalid_journal(
            "journal file has unsafe ownership or permissions",
        ));
    }
    if metadata.len() > MAX_NETWORK_ROLLBACK_JOURNAL_BYTES {
        return Err(invalid_journal("journal exceeds its size bound"));
    }
    Ok(())
}

pub(super) fn open_journal_directory(
    store: &NetworkRollbackStore,
) -> Result<fs::File, BackendError> {
    Ok(OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(&store.directory)?)
}

pub(super) fn load_network_rollbacks(
    store: &NetworkRollbackStore,
) -> Result<HashMap<uuid::Uuid, PendingNetworkRollback>, BackendError> {
    match fs::symlink_metadata(&store.directory) {
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(HashMap::new()),
        Err(error) => return Err(error.into()),
        Ok(_) => {}
    }
    validate_journal_parent(store)?;
    validate_journal_directory(store)?;
    let path = journal_path(store);
    let metadata = match fs::symlink_metadata(&path) {
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(HashMap::new()),
        Err(error) => return Err(error.into()),
        Ok(metadata) => metadata,
    };
    validate_journal_file(&metadata, store)?;
    let file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(path)?;
    validate_journal_file(&file.metadata()?, store)?;
    let mut bytes = Vec::new();
    file.take(MAX_NETWORK_ROLLBACK_JOURNAL_BYTES + 1)
        .read_to_end(&mut bytes)?;
    if bytes.len() as u64 > MAX_NETWORK_ROLLBACK_JOURNAL_BYTES {
        return Err(invalid_journal("journal exceeds its size bound"));
    }
    let journal: NetworkRollbackJournal =
        serde_json::from_slice(&bytes).map_err(|_| invalid_journal("journal JSON is invalid"))?;
    if journal.version != NETWORK_ROLLBACK_JOURNAL_VERSION {
        return Err(invalid_journal("journal version is unsupported"));
    }
    if journal.pending.len() > 1 {
        return Err(invalid_journal(
            "journal contains more than one pending network change",
        ));
    }
    if journal
        .pending
        .values()
        .any(|pending| !valid_network_rollback(&pending.rollback))
    {
        return Err(invalid_journal("journal contains a forbidden command"));
    }
    Ok(journal.pending)
}

pub(super) fn persist_network_rollbacks(
    store: &NetworkRollbackStore,
    pending: &HashMap<uuid::Uuid, PendingNetworkRollback>,
) -> Result<(), BackendError> {
    ensure_journal_directory(store)?;
    let path = journal_path(store);
    if pending.is_empty() {
        match fs::symlink_metadata(&path) {
            Ok(metadata) => {
                validate_journal_file(&metadata, store)?;
                fs::remove_file(&path)?;
                open_journal_directory(store)?.sync_all()?;
            }
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(error) => return Err(error.into()),
        }
        return Ok(());
    }
    if pending.len() != 1 {
        return Err(invalid_journal(
            "refusing to persist more than one pending network change",
        ));
    }
    if pending
        .values()
        .any(|pending| !valid_network_rollback(&pending.rollback))
    {
        return Err(invalid_journal("refusing to persist a forbidden command"));
    }
    if let Ok(metadata) = fs::symlink_metadata(&path) {
        validate_journal_file(&metadata, store)?;
    }
    let bytes = serde_json::to_vec(&NetworkRollbackJournal {
        version: NETWORK_ROLLBACK_JOURNAL_VERSION,
        pending: pending.clone(),
    })
    .map_err(|_| invalid_journal("journal could not be encoded"))?;
    if bytes.len() as u64 > MAX_NETWORK_ROLLBACK_JOURNAL_BYTES {
        return Err(invalid_journal("journal exceeds its size bound"));
    }
    let temporary_path = store
        .directory
        .join(format!(".pending-{}.tmp", uuid::Uuid::new_v4()));
    let result = (|| -> Result<(), BackendError> {
        let mut temporary = OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
            .open(&temporary_path)?;
        temporary.write_all(&bytes)?;
        temporary.sync_all()?;
        fs::rename(&temporary_path, &path)?;
        open_journal_directory(store)?.sync_all()?;
        validate_journal_file(&fs::symlink_metadata(&path)?, store)?;
        Ok(())
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temporary_path);
    }
    result
}
