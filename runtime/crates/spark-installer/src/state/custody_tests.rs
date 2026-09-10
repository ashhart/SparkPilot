use super::*;
use spark_core::identity::IdentityStore;

fn layout() -> (tempfile::TempDir, PathBuf, PathBuf, u32) {
    let temp = tempfile::tempdir().unwrap();
    let legacy = temp.path().join("legacy");
    let parent = temp.path().join("root");
    fs::create_dir(&parent).unwrap();
    fs::set_permissions(&parent, fs::Permissions::from_mode(0o700)).unwrap();
    FileIdentityStore::new(&legacy)
        .load_or_create("custody-test")
        .unwrap();
    sparkd::tls::load_or_create(&legacy).unwrap();
    let owner = unsafe { libc::geteuid() };
    (temp, legacy, parent, owner)
}

#[test]
fn custody_migration_preserves_authority_and_tls_across_retry() {
    let (_temp, legacy, parent, owner) = layout();
    let original = FileIdentityStore::new(&legacy).load().unwrap().unwrap();
    let fingerprint = sparkd::tls::fingerprint_at(&legacy.join("node.crt")).unwrap();
    let report = migrate_at(&legacy, &parent, owner).unwrap();
    assert!(report.migrated);
    let protected = load_vault(&parent.join("identity"), owner).unwrap();
    assert_eq!(protected.public, original.public);
    assert_eq!(
        protected.signing_key().to_bytes(),
        original.signing_key().to_bytes()
    );
    assert_eq!(
        sparkd::tls::fingerprint_at(&parent.join("identity/node.crt")).unwrap(),
        fingerprint
    );
    assert!(legacy.join("identity.key").exists());
    assert!(!migrate_at(&legacy, &parent, owner).unwrap().migrated);
    fs::remove_file(legacy.join("identity.key")).unwrap();
    fs::remove_file(legacy.join("node.key")).unwrap();
    assert!(!migrate_at(&legacy, &parent, owner).unwrap().migrated);
    assert!(FileIdentityStore::new(&legacy).load().is_err());
    assert_eq!(
        load_vault(&parent.join("identity"), owner).unwrap().public,
        original.public
    );
}

#[test]
fn custody_migration_refuses_partial_vault_without_using_legacy_seed() {
    let (_temp, legacy, parent, owner) = layout();
    fs::create_dir(parent.join("identity")).unwrap();
    fs::set_permissions(parent.join("identity"), fs::Permissions::from_mode(0o700)).unwrap();
    assert!(migrate_at(&legacy, &parent, owner).is_err());
    assert!(legacy.join("identity.key").exists());
    assert!(!parent.join("identity/identity.key").exists());
}

#[test]
fn custody_migration_refuses_redirected_or_exposed_legacy_tls_key() {
    let (_temp, legacy, parent, owner) = layout();
    let bytes = fs::read(legacy.join("node.key")).unwrap();
    fs::set_permissions(legacy.join("node.key"), fs::Permissions::from_mode(0o644)).unwrap();
    assert!(migrate_at(&legacy, &parent, owner).is_err());
    fs::remove_file(legacy.join("node.key")).unwrap();
    let target = parent.join("victim");
    fs::write(&target, &bytes).unwrap();
    std::os::unix::fs::symlink(&target, legacy.join("node.key")).unwrap();
    assert!(migrate_at(&legacy, &parent, owner).is_err());
    assert_eq!(fs::read(&target).unwrap(), bytes);
    assert!(!parent.join("identity").exists());
}

#[test]
fn incomplete_root_staging_can_restart_from_the_intact_legacy_identity() {
    let (_temp, legacy, parent, owner) = layout();
    fs::create_dir(parent.join(".identity.pending")).unwrap();
    fs::set_permissions(
        parent.join(".identity.pending"),
        fs::Permissions::from_mode(0o700),
    )
    .unwrap();
    fs::write(
        parent.join(".identity.pending/identity.key"),
        b"interrupted",
    )
    .unwrap();
    assert!(migrate_at(&legacy, &parent, owner).unwrap().migrated);
    assert!(!parent.join(".identity.pending").exists());
}
