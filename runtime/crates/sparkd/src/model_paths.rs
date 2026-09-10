//! Validate model identifiers before URL or filesystem use; signed recipes do not make remote manifests trusted input.

use std::path::{Component, Path, PathBuf};

const MAX_RELATIVE_PATH_BYTES: usize = 512;
const MAX_REPOSITORY_BYTES: usize = 200;

pub fn validate_relative_path(value: &str) -> Result<(), String> {
    if value.is_empty() || value.len() > MAX_RELATIVE_PATH_BYTES {
        return Err("model file path length is outside the supported range".into());
    }
    if value.contains(['\0', '\\']) {
        return Err("model file path contains a forbidden character".into());
    }
    let path = Path::new(value);
    if path.is_absolute()
        || value
            .split('/')
            .any(|segment| segment.is_empty() || matches!(segment, "." | ".."))
        || path
            .components()
            .any(|component| !matches!(component, Component::Normal(_)))
    {
        return Err(format!(
            "model file path is not a safe relative path: {value:?}"
        ));
    }
    Ok(())
}

pub fn validate_model_id(value: &str) -> Result<(), String> {
    validate_repository(value).map_err(|_| format!("model id is invalid: {value:?}"))
}

pub fn validate_repository(value: &str) -> Result<(), String> {
    if value.is_empty() || value.len() > MAX_REPOSITORY_BYTES || !value.is_ascii() {
        return Err("repository length or encoding is invalid".into());
    }
    let mut segments = value.split('/');
    let Some(owner) = segments.next() else {
        return Err("repository owner is missing".into());
    };
    let Some(name) = segments.next() else {
        return Err("repository must be owner/name".into());
    };
    if segments.next().is_some()
        || !safe_repository_segment(owner)
        || !safe_repository_segment(name)
    {
        return Err("repository must be a safe owner/name pair".into());
    }
    Ok(())
}

fn safe_repository_segment(value: &str) -> bool {
    !value.is_empty()
        && value != "."
        && value != ".."
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_' | b'.'))
}

pub fn validate_revision(value: &str) -> Result<(), String> {
    if value.len() != 40
        || !value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || matches!(byte, b'a'..=b'f'))
    {
        return Err("source revision must be 40 lowercase hexadecimal characters".into());
    }
    Ok(())
}

pub fn validate_sha256(value: &str) -> Result<(), String> {
    if value.len() != 64
        || !value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || matches!(byte, b'a'..=b'f'))
    {
        return Err("content digest must be 64 lowercase hexadecimal characters".into());
    }
    Ok(())
}

pub fn relative_join(root: &Path, value: &str) -> Result<PathBuf, String> {
    validate_relative_path(value)?;
    Ok(root.join(value))
}

pub fn snapshot_path(
    models_root: &Path,
    model_id: &str,
    revision: &str,
) -> Result<PathBuf, String> {
    validate_model_id(model_id)?;
    validate_revision(revision)?;
    Ok(models_root.join("snapshots").join(model_id).join(revision))
}

pub fn blob_path(models_root: &Path, digest: &str) -> Result<PathBuf, String> {
    validate_sha256(digest)?;
    Ok(models_root
        .join("blobs")
        .join("sha256")
        .join(&digest[..2])
        .join(digest))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn remote_paths_cannot_escape_the_model_root() {
        for value in [
            "",
            "/etc/passwd",
            "../etc/passwd",
            "weights/../../identity/key",
            "weights\\model.bin",
            "weights/./model.bin",
        ] {
            assert!(validate_relative_path(value).is_err(), "accepted {value:?}");
        }
        assert!(validate_relative_path(".gitattributes").is_ok());
        assert!(validate_relative_path("tokenizer/config.json").is_ok());
    }

    #[test]
    fn repositories_revisions_and_digests_are_strict() {
        assert!(validate_repository("acme/model-32b").is_ok());
        for value in [
            "model",
            "acme/model/extra",
            "../model",
            "acme/..",
            "acme/model?x",
        ] {
            assert!(validate_repository(value).is_err(), "accepted {value:?}");
        }
        assert!(validate_revision("0123456789abcdef0123456789abcdef01234567").is_ok());
        assert!(validate_revision("main").is_err());
        assert!(validate_sha256(&"a".repeat(64)).is_ok());
        assert!(validate_sha256(&"A".repeat(64)).is_err());
    }
}
