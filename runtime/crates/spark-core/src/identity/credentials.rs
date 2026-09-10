use super::*;
use std::io::Read;
use std::os::unix::fs::MetadataExt;

pub fn read_credential(directory: &Path, name: &str) -> Result<Zeroizing<Vec<u8>>, IdentityError> {
    if name.is_empty() || name.contains('/') || name.contains('\\') || name == "." || name == ".." {
        return Err(IdentityError::Corrupt(
            "credential name must be a filename".into(),
        ));
    }
    let metadata = fs::symlink_metadata(directory)?;
    if !metadata.is_dir()
        || metadata.file_type().is_symlink()
        || ![0o500, 0o550].contains(&(metadata.permissions().mode() & 0o777))
    {
        return Err(IdentityError::Corrupt(
            "credential directory must be a read-only 0500/0550 directory".into(),
        ));
    }
    let path = directory.join(name);
    let file = fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_CLOEXEC)
        .open(&path)?;
    let metadata = file.metadata()?;
    if !metadata.is_file()
        || ![0o400, 0o440].contains(&(metadata.permissions().mode() & 0o777))
        || metadata.nlink() != 1
        || metadata.len() > 64 * 1024
    {
        return Err(IdentityError::Corrupt(
            "credential must be a bounded, single-link, read-only 0400/0440 file".into(),
        ));
    }
    let mut bytes = Zeroizing::new(Vec::new());
    file.take(64 * 1024 + 1).read_to_end(&mut bytes)?;
    if bytes.len() > 64 * 1024 {
        return Err(IdentityError::Corrupt(
            "credential exceeds size limit".into(),
        ));
    }
    Ok(bytes)
}

pub fn load_credentials(directory: &Path) -> Result<NodeIdentity, IdentityError> {
    let bytes = read_credential(directory, KEY_FILE_NAME)?;
    if bytes.len() != 32 {
        return Err(IdentityError::Corrupt(
            "credential seed has wrong length".into(),
        ));
    }
    let mut seed = Zeroizing::new([0u8; 32]);
    seed.copy_from_slice(&bytes);
    let public = serde_json::from_slice(&read_credential(directory, PUBLIC_FILE_NAME)?)?;
    NodeIdentity::from_loaded(seed, public)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn readonly_credentials_preserve_authority_without_writing() {
        let temp = tempfile::tempdir().unwrap();
        let store = FileIdentityStore::new(temp.path().join("credentials"));
        let original = store.load_or_create("Credential Test").unwrap();
        for name in [KEY_FILE_NAME, PUBLIC_FILE_NAME] {
            fs::set_permissions(store.dir().join(name), fs::Permissions::from_mode(0o400)).unwrap();
        }
        fs::set_permissions(store.dir(), fs::Permissions::from_mode(0o500)).unwrap();
        let loaded = load_credentials(store.dir());
        fs::set_permissions(store.dir(), fs::Permissions::from_mode(0o700)).unwrap();
        let loaded = loaded.unwrap();
        assert_eq!(loaded.public, original.public);
        assert_eq!(
            loaded.signing_key().to_bytes(),
            original.signing_key().to_bytes()
        );
        assert_eq!(
            fs::metadata(store.dir().join(KEY_FILE_NAME))
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o400
        );
    }

    #[test]
    fn identity_debug_never_formats_the_private_seed() {
        let identity = NodeIdentity::from_seed(Zeroizing::new([42; 32]), "debug-test");
        let rendered = format!("{identity:?}");
        assert!(rendered.contains("<redacted>"));
        assert!(!rendered.contains("42, 42"));
    }
    #[test]
    fn systemd_acl_mask_credentials_preserve_the_authority() {
        let temp = tempfile::tempdir().unwrap();
        let store = FileIdentityStore::new(temp.path().join("credentials"));
        let original = store.load_or_create("Systemd ACL Test").unwrap();
        for name in [KEY_FILE_NAME, PUBLIC_FILE_NAME] {
            fs::set_permissions(store.dir().join(name), fs::Permissions::from_mode(0o440)).unwrap();
        }
        fs::set_permissions(store.dir(), fs::Permissions::from_mode(0o550)).unwrap();
        let loaded = load_credentials(store.dir());
        fs::set_permissions(store.dir(), fs::Permissions::from_mode(0o700)).unwrap();
        assert_eq!(loaded.unwrap().public, original.public);
    }
    #[test]
    fn credential_delivery_rejects_writes_world_access_links_and_missing_files() {
        let temp = tempfile::tempdir().unwrap();
        let store = FileIdentityStore::new(temp.path().join("credentials"));
        store.load_or_create("Credential Refusal Test").unwrap();
        let key = store.dir().join(KEY_FILE_NAME);
        fs::set_permissions(
            store.dir().join(PUBLIC_FILE_NAME),
            fs::Permissions::from_mode(0o400),
        )
        .unwrap();
        fs::set_permissions(store.dir(), fs::Permissions::from_mode(0o500)).unwrap();
        for mode in [0o600, 0o640, 0o444, 0o666] {
            fs::set_permissions(&key, fs::Permissions::from_mode(mode)).unwrap();
            assert!(load_credentials(store.dir()).is_err(), "mode {mode:o}");
        }
        fs::set_permissions(store.dir(), fs::Permissions::from_mode(0o700)).unwrap();
        fs::set_permissions(&key, fs::Permissions::from_mode(0o400)).unwrap();
        assert!(load_credentials(store.dir()).is_err());
        let target = temp.path().join("held-key");
        fs::rename(&key, &target).unwrap();
        std::os::unix::fs::symlink(&target, &key).unwrap();
        fs::set_permissions(store.dir(), fs::Permissions::from_mode(0o500)).unwrap();
        assert!(load_credentials(store.dir()).is_err());
        fs::set_permissions(store.dir(), fs::Permissions::from_mode(0o700)).unwrap();
        fs::remove_file(&key).unwrap();
        fs::set_permissions(store.dir(), fs::Permissions::from_mode(0o500)).unwrap();
        assert!(load_credentials(store.dir()).is_err());
        assert!(!key.exists());
        fs::set_permissions(store.dir(), fs::Permissions::from_mode(0o700)).unwrap();
    }
}
