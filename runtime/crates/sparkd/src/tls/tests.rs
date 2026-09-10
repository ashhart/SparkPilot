use super::*;
use spark_core::identity::{FileIdentityStore, IdentityStore};

fn directory() -> (tempfile::TempDir, PathBuf) {
    let root = tempfile::tempdir().unwrap();
    let identity = root.path().join("identity");
    (root, identity)
}

#[test]
fn creates_once_and_reuses_exact_leaf() {
    let (_root, directory) = directory();
    let first = load_or_create(&directory).unwrap();
    let second = load_or_create(&directory).unwrap();

    assert!(first.created);
    assert!(!second.created);
    assert_eq!(first.certificate_der, second.certificate_der);
    assert_eq!(first.fingerprint, second.fingerprint);
    assert_eq!(
        first.fingerprint,
        hex::encode(Sha256::digest(&first.certificate_der))
    );
}

#[test]
fn persisted_leaf_fingerprint_uses_the_validated_certificate_bytes() {
    let (_root, directory) = directory();
    let identity = load_or_create(&directory).unwrap();

    assert_eq!(
        fingerprint_at(&directory.join(CERTIFICATE_FILE_NAME)).unwrap(),
        identity.fingerprint
    );
}

#[test]
fn persisted_leaf_fingerprint_fails_closed_for_missing_or_corrupt_pem() {
    let (_root, directory) = directory();
    fs::create_dir(&directory).unwrap();
    fs::set_permissions(&directory, fs::Permissions::from_mode(DIRECTORY_MODE)).unwrap();
    let certificate_path = directory.join(CERTIFICATE_FILE_NAME);

    assert!(matches!(
        fingerprint_at(&certificate_path),
        Err(TlsIdentityError::Io { .. })
    ));

    fs::write(&certificate_path, b"not a certificate").unwrap();
    fs::set_permissions(
        &certificate_path,
        fs::Permissions::from_mode(CERTIFICATE_FILE_MODE),
    )
    .unwrap();
    assert!(matches!(
        fingerprint_at(&certificate_path),
        Err(TlsIdentityError::CorruptCertificate(_))
    ));
}

#[test]
fn tls_leaf_pin_is_not_the_owner_authority_fingerprint() {
    let (_root, directory) = directory();
    let owner = FileIdentityStore::new(&directory)
        .load_or_create("test-node")
        .unwrap();
    let tls = load_or_create(&directory).unwrap();

    assert_ne!(tls.fingerprint, owner.fingerprint());
}

#[test]
fn key_is_0600_and_creation_leaves_no_work_files() {
    let (_root, directory) = directory();
    load_or_create(&directory).unwrap();
    let mode = fs::metadata(directory.join(PRIVATE_KEY_FILE_NAME))
        .unwrap()
        .permissions()
        .mode()
        & 0o777;
    assert_eq!(mode, KEY_FILE_MODE);
    let names = fs::read_dir(&directory)
        .unwrap()
        .map(|entry| entry.unwrap().file_name().to_string_lossy().into_owned())
        .collect::<Vec<_>>();
    assert_eq!(
        names
            .iter()
            .filter(|name| name.contains(".tmp") || name.as_str() == CREATION_LOCK_FILE_NAME)
            .count(),
        0
    );
}

#[test]
fn partial_identity_fails_closed() {
    let (_root, directory) = directory();
    load_or_create(&directory).unwrap();
    fs::remove_file(directory.join(PRIVATE_KEY_FILE_NAME)).unwrap();
    assert!(matches!(
        load_or_create(&directory),
        Err(TlsIdentityError::PartialIdentity { .. })
    ));
}

#[test]
fn interrupted_creation_lock_fails_closed() {
    let (_root, directory) = directory();
    fs::create_dir(&directory).unwrap();
    fs::set_permissions(&directory, fs::Permissions::from_mode(DIRECTORY_MODE)).unwrap();
    let lock = directory.join(CREATION_LOCK_FILE_NAME);
    fs::write(&lock, b"").unwrap();
    fs::set_permissions(&lock, fs::Permissions::from_mode(KEY_FILE_MODE)).unwrap();

    assert!(matches!(
        load_or_create(&directory),
        Err(TlsIdentityError::InterruptedCreation { .. })
    ));
}

#[test]
fn mismatched_certificate_and_key_fail_closed() {
    let (_first_root, first) = directory();
    let (_second_root, second) = directory();
    load_or_create(&first).unwrap();
    load_or_create(&second).unwrap();
    fs::copy(
        second.join(PRIVATE_KEY_FILE_NAME),
        first.join(PRIVATE_KEY_FILE_NAME),
    )
    .unwrap();
    fs::set_permissions(
        first.join(PRIVATE_KEY_FILE_NAME),
        fs::Permissions::from_mode(KEY_FILE_MODE),
    )
    .unwrap();
    assert!(matches!(
        load_or_create(&first),
        Err(TlsIdentityError::CertificateKeyMismatch(_))
    ));
}

#[test]
fn corrupt_files_fail_closed() {
    let (_certificate_root, certificate_directory) = directory();
    load_or_create(&certificate_directory).unwrap();
    fs::write(
        certificate_directory.join(CERTIFICATE_FILE_NAME),
        b"not a certificate",
    )
    .unwrap();
    assert!(matches!(
        load_or_create(&certificate_directory),
        Err(TlsIdentityError::CorruptCertificate(_))
    ));

    let (_key_root, key_directory) = directory();
    load_or_create(&key_directory).unwrap();
    fs::write(key_directory.join(PRIVATE_KEY_FILE_NAME), b"not a key").unwrap();
    fs::set_permissions(
        key_directory.join(PRIVATE_KEY_FILE_NAME),
        fs::Permissions::from_mode(KEY_FILE_MODE),
    )
    .unwrap();
    assert!(matches!(
        load_or_create(&key_directory),
        Err(TlsIdentityError::CorruptPrivateKey(_))
    ));
}

#[test]
fn symlink_and_insecure_file_permissions_fail_closed() {
    use std::os::unix::fs::symlink;

    let (_symlink_root, symlink_directory) = directory();
    fs::create_dir(&symlink_directory).unwrap();
    fs::set_permissions(
        &symlink_directory,
        fs::Permissions::from_mode(DIRECTORY_MODE),
    )
    .unwrap();
    let (_target_root, target_directory) = directory();
    load_or_create(&target_directory).unwrap();
    symlink(
        target_directory.join(CERTIFICATE_FILE_NAME),
        symlink_directory.join(CERTIFICATE_FILE_NAME),
    )
    .unwrap();
    fs::copy(
        target_directory.join(PRIVATE_KEY_FILE_NAME),
        symlink_directory.join(PRIVATE_KEY_FILE_NAME),
    )
    .unwrap();
    fs::set_permissions(
        symlink_directory.join(PRIVATE_KEY_FILE_NAME),
        fs::Permissions::from_mode(KEY_FILE_MODE),
    )
    .unwrap();
    assert!(matches!(
        load_or_create(&symlink_directory),
        Err(TlsIdentityError::Symlink { .. })
    ));

    let (_insecure_root, insecure_directory) = directory();
    load_or_create(&insecure_directory).unwrap();
    fs::set_permissions(
        insecure_directory.join(PRIVATE_KEY_FILE_NAME),
        fs::Permissions::from_mode(0o640),
    )
    .unwrap();
    assert!(matches!(
        load_or_create(&insecure_directory),
        Err(TlsIdentityError::InsecureKeyPermissions { .. })
    ));

    let (_certificate_root, certificate_directory) = directory();
    load_or_create(&certificate_directory).unwrap();
    fs::set_permissions(
        certificate_directory.join(CERTIFICATE_FILE_NAME),
        fs::Permissions::from_mode(0o666),
    )
    .unwrap();
    assert!(matches!(
        load_or_create(&certificate_directory),
        Err(TlsIdentityError::InsecureCertificatePermissions { .. })
    ));
}
