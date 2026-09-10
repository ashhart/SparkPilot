use super::*;

fn enrolled() -> (tempfile::TempDir, FileIdentityStore, NodeIdentity) {
    let dir = tempfile::tempdir().unwrap();
    let store = FileIdentityStore::new(dir.path().join("identity"));
    let identity = store.load_or_create("Test Spark").unwrap();
    (dir, store, identity)
}

/// A surviving seed without its public record must fail closed without replacing the authority or destroying recovery evidence.
#[test]
fn a_surviving_private_key_without_its_public_record_fails_closed() {
    let (dir, store, original) = enrolled();
    let public_path = dir.path().join("identity").join(PUBLIC_FILE_NAME);
    let key_path = dir.path().join("identity").join(KEY_FILE_NAME);
    let seed_before = fs::read(&key_path).unwrap();
    fs::remove_file(&public_path).unwrap();

    let error = store.load_or_create("Test Spark").unwrap_err();
    assert!(
        matches!(error, IdentityError::PartialIdentity { .. }),
        "expected a partial-identity refusal, got {error:?}"
    );
    assert!(store.load().is_err());

    // The surviving half is untouched, so the node can still be restored.
    assert_eq!(fs::read(&key_path).unwrap(), seed_before);
    assert_eq!(seed_before.len(), 32);
    let _ = original;
}

#[test]
fn a_surviving_public_record_without_its_key_fails_closed() {
    let (dir, store, original) = enrolled();
    let key_path = dir.path().join("identity").join(KEY_FILE_NAME);
    let public_before = fs::read(dir.path().join("identity").join(PUBLIC_FILE_NAME)).unwrap();
    fs::remove_file(&key_path).unwrap();

    let error = store.load_or_create("Test Spark").unwrap_err();
    assert!(
        matches!(error, IdentityError::PartialIdentity { .. }),
        "expected a partial-identity refusal, got {error:?}"
    );
    assert_eq!(
        fs::read(dir.path().join("identity").join(PUBLIC_FILE_NAME)).unwrap(),
        public_before
    );
    let _ = original;
}

#[test]
fn a_complete_identity_still_loads_and_an_empty_directory_still_enrols() {
    let (_dir, store, original) = enrolled();
    let reloaded = store.load_or_create("A Different Name").unwrap();
    assert_eq!(reloaded.node_id(), original.node_id());
    assert_eq!(reloaded.fingerprint(), original.fingerprint());

    let fresh_dir = tempfile::tempdir().unwrap();
    let fresh = FileIdentityStore::new(fresh_dir.path().join("identity"));
    assert!(fresh.load().unwrap().is_none());
    let created = fresh.load_or_create("New Spark").unwrap();
    assert_ne!(created.node_id(), original.node_id());
}
