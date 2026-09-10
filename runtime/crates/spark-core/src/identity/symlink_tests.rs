use super::*;

/// Refuse dangling key-path symlinks so initialization cannot write the private seed through them.
#[test]
fn a_dangling_symlink_where_the_key_belongs_is_refused() {
    let dir = tempfile::tempdir().unwrap();
    let identity_dir = dir.path().join("identity");
    fs::create_dir_all(&identity_dir).unwrap();
    let elsewhere = dir.path().join("elsewhere");
    std::os::unix::fs::symlink(&elsewhere, identity_dir.join(KEY_FILE_NAME)).unwrap();

    let store = FileIdentityStore::new(&identity_dir);
    let error = store.load_or_create("Test Spark").unwrap_err();
    assert!(
        matches!(error, IdentityError::NotARegularFile { .. }),
        "expected a refusal, got {error:?}"
    );
    assert!(!elsewhere.exists(), "nothing was written through the link");
}

#[test]
fn an_existing_symlink_where_the_key_belongs_is_refused() {
    let dir = tempfile::tempdir().unwrap();
    let identity_dir = dir.path().join("identity");
    fs::create_dir_all(&identity_dir).unwrap();
    let target = dir.path().join("target");
    fs::write(&target, b"someone else's file").unwrap();
    std::os::unix::fs::symlink(&target, identity_dir.join(KEY_FILE_NAME)).unwrap();

    let store = FileIdentityStore::new(&identity_dir);
    assert!(matches!(
        store.load_or_create("Test Spark").unwrap_err(),
        IdentityError::NotARegularFile { .. }
    ));
    assert!(matches!(
        store.load().unwrap_err(),
        IdentityError::NotARegularFile { .. }
    ));
    assert_eq!(fs::read(&target).unwrap(), b"someone else's file");
}

#[test]
fn a_symlinked_public_record_is_refused() {
    let dir = tempfile::tempdir().unwrap();
    let identity_dir = dir.path().join("identity");
    let store = FileIdentityStore::new(&identity_dir);
    store.load_or_create("Test Spark").unwrap();

    let public = identity_dir.join(PUBLIC_FILE_NAME);
    let target = dir.path().join("target.json");
    fs::write(&target, b"{}").unwrap();
    fs::remove_file(&public).unwrap();
    std::os::unix::fs::symlink(&target, &public).unwrap();

    assert!(matches!(
        store.load().unwrap_err(),
        IdentityError::NotARegularFile { .. }
    ));
    assert_eq!(fs::read(&target).unwrap(), b"{}");
}

#[test]
fn a_directory_where_the_key_belongs_is_refused() {
    let dir = tempfile::tempdir().unwrap();
    let identity_dir = dir.path().join("identity");
    fs::create_dir_all(identity_dir.join(KEY_FILE_NAME)).unwrap();

    let store = FileIdentityStore::new(&identity_dir);
    assert!(matches!(
        store.load_or_create("Test Spark").unwrap_err(),
        IdentityError::NotARegularFile { .. }
    ));
}

/// Persistence must refuse a symlink appearing between inspection and exclusive creation.
#[test]
fn persisting_never_writes_through_a_link_that_appeared_late() {
    let dir = tempfile::tempdir().unwrap();
    let identity_dir = dir.path().join("identity");
    fs::create_dir_all(&identity_dir).unwrap();

    let target = dir.path().join("victim");
    fs::write(&target, b"root content").unwrap();
    // Refuse a public-record symlink during state inspection; exclusive no-follow creation also prevents following a later substitution.
    std::os::unix::fs::symlink(&target, identity_dir.join(PUBLIC_FILE_NAME)).unwrap();

    let store = FileIdentityStore::new(&identity_dir);
    assert!(store.load_or_create("Test Spark").is_err());
    assert_eq!(fs::read(&target).unwrap(), b"root content");
}
