use super::*;

/// Accept only a lowercase-leading safe path component, excluding traversal and dot directories.
pub fn validate_release_id(release_id: &str) -> Result<(), UpdateError> {
    let bytes = release_id.as_bytes();
    if bytes.is_empty() || bytes.len() > RELEASE_ID_MAX {
        return Err(UpdateError::refused(
            "UPDATE_RELEASE_ID_INVALID release id length is outside the allowed range",
        ));
    }
    if bytes.len() < RELEASE_ID_MIN {
        return Err(UpdateError::refused(
            "UPDATE_RELEASE_ID_INVALID release id is too short",
        ));
    }
    if !bytes[0].is_ascii_lowercase() {
        return Err(UpdateError::refused(
            "UPDATE_RELEASE_ID_INVALID release id must start with a lowercase letter",
        ));
    }
    if !bytes
        .iter()
        .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || matches!(b, b'.' | b'_' | b'-'))
    {
        return Err(UpdateError::refused(
            "UPDATE_RELEASE_ID_INVALID release id allows only lowercase letters, digits, '.', '_', '-'",
        ));
    }
    Ok(())
}

/// The report `spark-installer verify-package` prints on stdout.
pub(super) struct VerifyReport {
    pub(super) sha256: Option<String>,
}

pub(super) struct Seal {
    pub(super) directory: PathBuf,
    pub(super) package: PathBuf,
}

pub(super) fn sha256_file(path: &Path) -> Result<String, UpdateError> {
    let mut file = fs::File::open(path)?;
    let mut hasher = sha2::Sha256::new();
    let mut buf = [0u8; 64 * 1024];
    loop {
        let read = file.read(&mut buf)?;
        if read == 0 {
            break;
        }
        hasher.update(&buf[..read]);
    }
    Ok(hex::encode(hasher.finalize()))
}
