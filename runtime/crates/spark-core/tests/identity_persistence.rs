//! Keep identity stable across restart and refuse insecure permissions or damaged private material without regenerating authority.

use std::os::unix::fs::PermissionsExt;

use spark_core::identity::{FileIdentityStore, IdentityStore, KEY_FILE_NAME, NodeIdentity};
use tempfile::tempdir;

fn load(dir: &std::path::Path) -> Result<NodeIdentity, spark_core::identity::IdentityError> {
    FileIdentityStore::new(dir).load_or_create("persistence-test")
}

#[test]
fn identity_persists_across_restart() {
    let dir = tempdir().unwrap();
    let first = load(dir.path()).expect("create");
    std::mem::drop(first);

    let second = load(dir.path()).expect("reload");
    assert_eq!(
        second.public,
        FileIdentityStore::new(dir.path())
            .load_or_create("persistence-test")
            .expect("reload twice")
            .public
    );
    let third = FileIdentityStore::new(dir.path())
        .load_or_create("persistence-test")
        .expect("reload twice");
    assert_eq!(second.node_id(), third.node_id());
    assert_eq!(second.fingerprint(), third.fingerprint());
    assert_eq!(
        second.signing_key().to_bytes(),
        third.signing_key().to_bytes()
    );
}

#[test]
fn key_permissions_fail_closed() {
    let dir = tempdir().unwrap();
    load(dir.path()).expect("create");
    let key_path = dir.path().join(KEY_FILE_NAME);
    std::fs::set_permissions(&key_path, std::fs::Permissions::from_mode(0o644)).unwrap();

    // Refuse insecure key permissions even when this process can read the file.
    let err = load(dir.path()).expect_err("loading a world-readable key must fail");
    match err {
        spark_core::identity::IdentityError::InsecureKeyPermissions { mode, .. } => {
            assert_eq!(mode, 0o644);
        }
        other => panic!("unexpected error: {other}"),
    }
}

#[test]
fn missing_key_is_not_regenerated() {
    let dir = tempdir().unwrap();
    load(dir.path()).expect("create");
    std::fs::remove_file(dir.path().join(KEY_FILE_NAME)).unwrap();

    // PartialIdentity identifies the surviving half for restoration; a missing key must never be regenerated.
    let err = load(dir.path()).expect_err("missing key must not be silently regenerated");
    assert!(
        matches!(
            err,
            spark_core::identity::IdentityError::PartialIdentity { .. }
        ),
        "unexpected error: {err}"
    );
}

/// A surviving seed with no public record must remain untouched rather than being replaced by a new authority.
#[test]
fn missing_public_record_does_not_re_key_the_node() {
    let dir = tempdir().unwrap();
    load(dir.path()).expect("create");
    let key_before = std::fs::read(dir.path().join(KEY_FILE_NAME)).unwrap();
    std::fs::remove_file(dir.path().join("identity.json")).unwrap();

    let err = load(dir.path()).expect_err("a surviving seed must not be replaced");
    assert!(
        matches!(
            err,
            spark_core::identity::IdentityError::PartialIdentity { .. }
        ),
        "unexpected error: {err}"
    );
    assert_eq!(
        std::fs::read(dir.path().join(KEY_FILE_NAME)).unwrap(),
        key_before,
        "the surviving seed is the only copy of this node's authority"
    );
}

#[test]
fn tampered_public_record_is_rejected() {
    let dir = tempdir().unwrap();
    let original = load(dir.path()).expect("create");

    // Corrupt the stored public key by one byte.
    let public_path = dir.path().join("identity.json");
    let mut json: serde_json::Value =
        serde_json::from_str(&std::fs::read_to_string(&public_path).unwrap()).unwrap();
    let mut key = hex::decode(json["authority_public_key"].as_str().unwrap()).unwrap();
    let last = key.last_mut().unwrap();
    *last = (*last).wrapping_add(1);
    json["authority_public_key"] = serde_json::Value::String(hex::encode(key));
    std::fs::write(&public_path, serde_json::to_vec_pretty(&json).unwrap()).unwrap();

    let err = load(dir.path()).expect_err("mismatched public record must be rejected");
    assert!(
        matches!(
            err,
            spark_core::identity::IdentityError::PublicMismatch
                | spark_core::identity::IdentityError::Corrupt(_)
        ),
        "unexpected error: {err}"
    );
    // The in-memory identity from before remains usable.
    assert_eq!(original.fingerprint().len(), 64);
}
