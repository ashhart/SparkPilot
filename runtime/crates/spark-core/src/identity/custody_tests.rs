use super::*;

/// Pin current key custody and its package-channel gate; production custody changes must update both assertions.
#[test]
fn the_private_key_is_owner_only_and_fails_closed_otherwise() {
    let dir = tempfile::tempdir().unwrap();
    let store = FileIdentityStore::new(dir.path().join("identity"));
    store.load_or_create("Custody Test").unwrap();

    let key_path = dir.path().join("identity").join(KEY_FILE_NAME);
    let mode = fs::metadata(&key_path).unwrap().permissions().mode() & 0o777;
    assert_eq!(mode, 0o600, "the private key must be owner-only");

    let dir_mode = fs::metadata(dir.path().join("identity"))
        .unwrap()
        .permissions()
        .mode()
        & 0o777;
    assert_eq!(dir_mode, 0o700, "the identity directory must be owner-only");

    // Refuse widened key permissions rather than hiding prior exposure by silently tightening them.
    for loosened in [0o640, 0o644, 0o660, 0o666] {
        fs::set_permissions(&key_path, fs::Permissions::from_mode(loosened)).unwrap();
        let error = store.load().unwrap_err();
        assert!(
            matches!(error, IdentityError::InsecureKeyPermissions { mode, .. } if mode == loosened),
            "mode 0o{loosened:o} must fail closed, got {error:?}"
        );
    }

    // Keep declared custody, package gating and build evidence aligned with the enforced service-account-0600 storage.
    assert_eq!(PRIVATE_KEY_CUSTODY, "service-account-0600");
}
