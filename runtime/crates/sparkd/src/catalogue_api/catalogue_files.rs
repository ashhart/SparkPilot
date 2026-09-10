use super::*;

pub(super) fn previous_path(path: &Path) -> PathBuf {
    let name = path
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("catalogue.json");
    path.with_file_name(format!("{name}.previous"))
}

pub(super) fn temporary_path(
    path: &Path,
    operation_id: uuid::Uuid,
) -> Result<PathBuf, CatalogueRefreshError> {
    let name = path
        .file_name()
        .and_then(|name| name.to_str())
        .ok_or_else(|| CatalogueRefreshError::Promotion("catalogue filename is invalid".into()))?;
    Ok(path.with_file_name(format!(".{name}.candidate-{operation_id}")))
}

pub(super) fn validate_parent(path: &Path) -> Result<(), CatalogueRefreshError> {
    let parent = path
        .parent()
        .ok_or_else(|| CatalogueRefreshError::NonRegular(path.display().to_string()))?;
    let metadata = fs::symlink_metadata(parent)
        .map_err(|error| CatalogueRefreshError::Promotion(error.to_string()))?;
    if metadata.file_type().is_symlink() || !metadata.is_dir() {
        return Err(CatalogueRefreshError::NonRegular(
            parent.display().to_string(),
        ));
    }
    Ok(())
}

pub(super) fn validate_regular_if_present(path: &Path) -> Result<(), CatalogueRefreshError> {
    let metadata = match fs::symlink_metadata(path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(error) => return Err(CatalogueRefreshError::Promotion(error.to_string())),
    };
    if metadata.file_type().is_symlink() || !metadata.is_file() {
        return Err(CatalogueRefreshError::NonRegular(
            path.display().to_string(),
        ));
    }
    Ok(())
}

pub(super) fn safe_read(
    path: &Path,
    maximum: usize,
) -> Result<Option<Vec<u8>>, CatalogueRefreshError> {
    let file = match OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(path)
    {
        Ok(file) => file,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) if error.raw_os_error() == Some(libc::ELOOP) => {
            return Err(CatalogueRefreshError::NonRegular(
                path.display().to_string(),
            ));
        }
        Err(error) => return Err(CatalogueRefreshError::Promotion(error.to_string())),
    };
    let metadata = file
        .metadata()
        .map_err(|error| CatalogueRefreshError::Promotion(error.to_string()))?;
    if !metadata.is_file() {
        return Err(CatalogueRefreshError::NonRegular(
            path.display().to_string(),
        ));
    }
    if metadata.len() > maximum as u64 {
        return Err(CatalogueRefreshError::TooLarge);
    }
    let mut bytes = Vec::with_capacity(metadata.len() as usize);
    file.take(maximum as u64 + 1)
        .read_to_end(&mut bytes)
        .map_err(|error| CatalogueRefreshError::Promotion(error.to_string()))?;
    if bytes.len() > maximum {
        return Err(CatalogueRefreshError::TooLarge);
    }
    Ok(Some(bytes))
}

pub(super) fn write_staged_file(path: &Path, bytes: &[u8]) -> Result<(), CatalogueRefreshError> {
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(path)
        .map_err(|error| CatalogueRefreshError::Promotion(error.to_string()))?;
    file.write_all(bytes)
        .and_then(|_| file.sync_all())
        .map_err(|error| CatalogueRefreshError::Promotion(error.to_string()))
}

pub(super) fn stage_candidate(path: &Path, bytes: &[u8]) -> Result<(), CatalogueRefreshError> {
    match safe_read(path, MAX_CATALOGUE_BYTES)? {
        Some(existing) if existing == bytes => return Ok(()),
        Some(_) => {
            fs::remove_file(path)
                .map_err(|error| CatalogueRefreshError::Promotion(error.to_string()))?;
            sync_directory(
                path.parent()
                    .ok_or_else(|| CatalogueRefreshError::Promotion("missing parent".into()))?,
            )?;
        }
        None => {}
    }
    write_staged_file(path, bytes)
}

pub(super) fn sync_directory(path: &Path) -> Result<(), CatalogueRefreshError> {
    File::open(path)
        .and_then(|directory| directory.sync_all())
        .map_err(|error| CatalogueRefreshError::Promotion(error.to_string()))
}

pub(super) fn safe_load_catalogue(
    path: &Path,
    root: &CatalogueRoot,
) -> Result<SignedCatalogue, CatalogueRefreshError> {
    let bytes = safe_read(path, MAX_CATALOGUE_BYTES)?.ok_or(CatalogueRefreshError::Unavailable)?;
    let catalogue: SignedCatalogue = serde_json::from_slice(&bytes)
        .map_err(|error| CatalogueRefreshError::InvalidJson(error.to_string()))?;
    catalogue
        .verify(root)
        .map_err(|error| CatalogueRefreshError::Verification(error.to_string()))?;
    Ok(catalogue)
}

pub(super) fn rollback_or(
    primary: CatalogueRefreshError,
    current: &Path,
    previous: &Path,
    moved_current: bool,
) -> CatalogueRefreshError {
    match rollback_files(current, previous, moved_current) {
        Ok(()) => primary,
        Err(rollback) => {
            CatalogueRefreshError::Promotion(format!("{primary}; rollback failed: {rollback}"))
        }
    }
}

pub(super) fn rollback_files(
    current: &Path,
    previous: &Path,
    moved_current: bool,
) -> Result<(), CatalogueRefreshError> {
    if current
        .symlink_metadata()
        .is_ok_and(|metadata| metadata.is_file() && !metadata.file_type().is_symlink())
    {
        fs::remove_file(current)
            .map_err(|error| CatalogueRefreshError::Promotion(error.to_string()))?;
    }
    if moved_current {
        fs::rename(previous, current)
            .map_err(|error| CatalogueRefreshError::Promotion(error.to_string()))?;
    }
    if let Some(parent) = current.parent() {
        sync_directory(parent)?;
    }
    Ok(())
}

/// Restore the previous snapshot only when interrupted promotion left current absent; never replace an existing current file during startup.
pub fn recover_interrupted_promotion(path: &Path) -> Result<bool, CatalogueRefreshError> {
    validate_parent(path)?;
    validate_regular_if_present(path)?;
    let previous = previous_path(path);
    validate_regular_if_present(&previous)?;
    if path.exists() || !previous.exists() {
        return Ok(false);
    }
    fs::rename(&previous, path)
        .map_err(|error| CatalogueRefreshError::Promotion(error.to_string()))?;
    sync_directory(
        path.parent()
            .ok_or_else(|| CatalogueRefreshError::Promotion("missing parent".into()))?,
    )?;
    Ok(true)
}
