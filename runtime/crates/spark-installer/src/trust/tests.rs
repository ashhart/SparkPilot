use super::*;
use ed25519_dalek::{Signer, SigningKey};

fn signing_key() -> SigningKey {
    SigningKey::from_bytes(&[7u8; 32])
}

fn trust_root_json(revoked: bool, channels: &[&str]) -> String {
    trust_root_with(revoked, channels, &[MANIFEST_PURPOSE, PACKAGE_PURPOSE])
}

fn trust_root_with(revoked: bool, channels: &[&str], purposes: &[&str]) -> String {
    let public = hex::encode(signing_key().verifying_key().to_bytes());
    serde_json::json!({
        "schema": 1,
        "keys": [{
            "key_id": "test-key",
            "algorithm": "ed25519",
            "public_key": public,
            "channels": channels,
            "purposes": purposes,
            "not_before": "2026-01-01T00:00:00Z",
            "not_after": "2027-01-01T00:00:00Z",
            "revoked_at": if revoked { Some("2026-06-01T00:00:00Z") } else { None },
        }]
    })
    .to_string()
}

fn signed_manifest(channel: &str) -> String {
    let mut manifest: serde_json::Value = serde_json::json!({
        "version": "0.1.0",
        "channel": channel,
        "released_at": "2026-08-27T00:00:00Z",
        "minimum_dgx_os": "7.0",
        "artifacts": [{
            "name": "spark-runtime.deb",
            "architecture": "aarch64",
            "url": "https://x.invalid/a.deb",
            "size": 10,
            "sha256": "c".repeat(64),
            "signature_url": "https://x.invalid/a.deb.sig"
        }]
    });
    let canonical = serde_json::to_vec(&manifest).unwrap();
    let signature = signing_key().sign(&canonical);
    use base64::Engine;
    use base64::engine::general_purpose::URL_SAFE_NO_PAD;
    manifest["signature"] = serde_json::json!({
        "key_id": "test-key",
        "algorithm": "ed25519",
        "value": URL_SAFE_NO_PAD.encode(signature.to_bytes()),
    });
    serde_json::to_string(&manifest).unwrap()
}

fn at(text: &str) -> OffsetDateTime {
    OffsetDateTime::parse(text, &Rfc3339).unwrap()
}

#[test]
fn verifies_a_correctly_signed_manifest() {
    let root = ReleaseTrustRoot::from_json(trust_root_json(false, &["dev"]).as_bytes()).unwrap();
    let verified = root
        .verify_manifest(
            signed_manifest("dev").as_bytes(),
            at("2026-08-27T00:00:00Z"),
        )
        .unwrap();
    assert_eq!(verified.key_id, "test-key");
    assert_eq!(verified.manifest.version, "0.1.0");
}

#[test]
fn rejects_a_tampered_digest() {
    let root = ReleaseTrustRoot::from_json(trust_root_json(false, &["dev"]).as_bytes()).unwrap();
    let tampered = signed_manifest("dev").replace(&"c".repeat(64), &"d".repeat(64));
    assert!(matches!(
        root.verify_manifest(tampered.as_bytes(), at("2026-08-27T00:00:00Z")),
        Err(TrustError::SignatureInvalid(_))
    ));
}

#[test]
fn rejects_a_tampered_url() {
    let root = ReleaseTrustRoot::from_json(trust_root_json(false, &["dev"]).as_bytes()).unwrap();
    let tampered = signed_manifest("dev").replace("https://x.invalid", "https://evil.invalid");
    assert!(matches!(
        root.verify_manifest(tampered.as_bytes(), at("2026-08-27T00:00:00Z")),
        Err(TrustError::SignatureInvalid(_))
    ));
}

#[test]
fn rejects_an_unknown_key_id() {
    let root = ReleaseTrustRoot::from_json(trust_root_json(false, &["dev"]).as_bytes()).unwrap();
    let other = signed_manifest("dev").replace("test-key", "someone-elses-key");
    assert!(matches!(
        root.verify_manifest(other.as_bytes(), at("2026-08-27T00:00:00Z")),
        Err(TrustError::UnknownKeyId(_))
    ));
}

#[test]
fn rejects_a_revoked_key() {
    let root = ReleaseTrustRoot::from_json(trust_root_json(true, &["dev"]).as_bytes()).unwrap();
    assert!(matches!(
        root.verify_manifest(
            signed_manifest("dev").as_bytes(),
            at("2026-08-27T00:00:00Z")
        ),
        Err(TrustError::RevokedKey(_))
    ));
}

#[test]
fn rejects_a_key_outside_its_validity_window() {
    let root = ReleaseTrustRoot::from_json(trust_root_json(false, &["dev"]).as_bytes()).unwrap();
    assert!(matches!(
        root.verify_manifest(
            signed_manifest("dev").as_bytes(),
            at("2028-01-01T00:00:00Z")
        ),
        Err(TrustError::KeyNotValidYet { .. })
    ));
}

#[test]
fn rejects_a_channel_the_key_does_not_cover() {
    let root = ReleaseTrustRoot::from_json(trust_root_json(false, &["dev"]).as_bytes()).unwrap();
    assert!(matches!(
        root.verify_manifest(
            signed_manifest("stable").as_bytes(),
            at("2026-08-27T00:00:00Z")
        ),
        Err(TrustError::ChannelNotAuthorised { .. })
    ));
}

#[test]
fn rejects_an_unsigned_manifest() {
    let root = ReleaseTrustRoot::from_json(trust_root_json(false, &["dev"]).as_bytes()).unwrap();
    let unsigned: serde_json::Value = serde_json::from_str(&signed_manifest("dev"))
        .map(|mut value: serde_json::Value| {
            value.as_object_mut().unwrap().remove("signature");
            value
        })
        .unwrap();
    assert!(matches!(
        root.verify_manifest(unsigned.to_string().as_bytes(), at("2026-08-27T00:00:00Z")),
        Err(TrustError::Manifest(ManifestError::MissingSignature))
    ));
}

#[test]
fn verifies_and_rejects_detached_signatures() {
    let root = ReleaseTrustRoot::from_json(trust_root_json(false, &["dev"]).as_bytes()).unwrap();
    let payload = b"package bytes";
    let signature = signing_key().sign(payload).to_bytes();
    let now = at("2026-08-27T00:00:00Z");
    assert!(
        root.verify_detached("test-key", payload, &signature, now, "dev")
            .is_ok()
    );
    assert!(matches!(
        root.verify_detached("test-key", b"other bytes", &signature, now, "dev"),
        Err(TrustError::SignatureInvalid(_))
    ));
    assert!(matches!(
        root.verify_detached("test-key", payload, &signature[..32], now, "dev"),
        Err(TrustError::SignatureInvalid(_))
    ));
}

#[test]
fn rejects_a_catalogue_key_asked_to_sign_a_release() {
    // Catalogue and package key purposes must remain distinct (§45.3).
    let root = ReleaseTrustRoot::from_json(
        trust_root_with(false, &["dev"], &[CATALOGUE_PURPOSE]).as_bytes(),
    )
    .unwrap();
    assert!(matches!(
        root.verify_manifest(
            signed_manifest("dev").as_bytes(),
            at("2026-08-27T00:00:00Z")
        ),
        Err(TrustError::PurposeNotAuthorised { .. })
    ));
}

#[test]
fn a_manifest_key_may_not_sign_a_package() {
    let root = ReleaseTrustRoot::from_json(
        trust_root_with(false, &["dev"], &[MANIFEST_PURPOSE]).as_bytes(),
    )
    .unwrap();
    let signature = signing_key().sign(b"package bytes").to_bytes();
    assert!(matches!(
        root.verify_detached(
            "test-key",
            b"package bytes",
            &signature,
            at("2026-08-27T00:00:00Z"),
            "dev"
        ),
        Err(TrustError::PurposeNotAuthorised { .. })
    ));
}

#[test]
fn a_direct_trust_root_may_not_vouch_for_production_channels() {
    // Even a valid, in-window, correctly scoped schema-1 signature cannot authorize production without offline delegation.
    let root = ReleaseTrustRoot::from_json(trust_root_json(false, &["stable"]).as_bytes()).unwrap();
    assert!(matches!(
        root.verify_manifest(
            signed_manifest("stable").as_bytes(),
            at("2026-08-27T00:00:00Z")
        ),
        Err(TrustError::DelegationRequired(channel)) if channel == "stable"
    ));
}

#[test]
fn rotation_moves_trust_to_the_new_key_only() {
    // Accept the live rotation key and reject the revoked key within the same trust root.
    let old_key = SigningKey::from_bytes(&[11u8; 32]);
    let new_key = signing_key();
    let json = serde_json::json!({
        "schema": 1,
        "keys": [
            {
                "key_id": "old-key",
                "algorithm": "ed25519",
                "public_key": hex::encode(old_key.verifying_key().to_bytes()),
                "channels": ["dev"],
                "purposes": [MANIFEST_PURPOSE],
                "not_before": "2026-01-01T00:00:00Z",
                "not_after": "2027-01-01T00:00:00Z",
                "revoked_at": "2026-06-01T00:00:00Z"
            },
            {
                "key_id": "test-key",
                "algorithm": "ed25519",
                "public_key": hex::encode(new_key.verifying_key().to_bytes()),
                "channels": ["dev"],
                "purposes": [MANIFEST_PURPOSE],
                "not_before": "2026-01-01T00:00:00Z",
                "not_after": "2027-01-01T00:00:00Z"
            }
        ]
    })
    .to_string();
    let root = ReleaseTrustRoot::from_json(json.as_bytes()).unwrap();

    let now = at("2026-08-27T00:00:00Z");
    assert!(
        root.verify_manifest(signed_manifest("dev").as_bytes(), now)
            .is_ok()
    );

    let under_old = signed_manifest("dev").replace("test-key", "old-key");
    assert!(matches!(
        root.verify_manifest(under_old.as_bytes(), now),
        Err(TrustError::RevokedKey(_))
    ));
}

#[test]
fn tampered_trust_metadata_is_rejected() {
    // Malformed edits to trust windows or scopes must fail closed; valid trust-document changes remain the distributor's authority.
    let widened = trust_root_json(false, &["dev"]).replace("\"dev\"", "\"stable\"");
    let root = ReleaseTrustRoot::from_json(widened.as_bytes()).unwrap();
    assert!(matches!(
        root.verify_manifest(
            signed_manifest("dev").as_bytes(),
            at("2026-08-27T00:00:00Z")
        ),
        Err(TrustError::ChannelNotAuthorised { .. })
    ));

    let bad_purpose = trust_root_json(false, &["dev"]).replace(MANIFEST_PURPOSE, "anything");
    assert!(matches!(
        ReleaseTrustRoot::from_json(bad_purpose.as_bytes()),
        Err(TrustError::InvalidKey { .. })
    ));

    let no_purpose = trust_root_json(false, &["dev"])
        .replace(&format!("\"{MANIFEST_PURPOSE}\",\"{PACKAGE_PURPOSE}\""), "");
    assert!(ReleaseTrustRoot::from_json(no_purpose.as_bytes()).is_err());
}

#[test]
fn rejects_a_trust_root_with_no_keys() {
    let empty = serde_json::json!({"schema": 1, "keys": []}).to_string();
    assert!(matches!(
        ReleaseTrustRoot::from_json(empty.as_bytes()),
        Err(TrustError::Empty)
    ));
}

#[test]
fn rejects_a_trust_root_from_a_future_schema() {
    let future = serde_json::json!({"schema": 99, "keys": []}).to_string();
    assert!(matches!(
        ReleaseTrustRoot::from_json(future.as_bytes()),
        Err(TrustError::UnsupportedSchema(99))
    ));
}

#[test]
fn rejects_a_trust_root_that_lists_one_key_id_twice() {
    let public = hex::encode(signing_key().verifying_key().to_bytes());
    let json = serde_json::json!({
        "schema": 1,
        "keys": [
            {
                "key_id": "test-key",
                "algorithm": "ed25519",
                "public_key": public,
                "channels": ["dev"],
                "purposes": [MANIFEST_PURPOSE],
                "not_before": "2026-01-01T00:00:00Z",
                "not_after": "2027-01-01T00:00:00Z",
                "revoked_at": "2026-06-01T00:00:00Z"
            },
            {
                "key_id": "test-key",
                "algorithm": "ed25519",
                "public_key": public,
                "channels": ["dev", "lab"],
                "purposes": [MANIFEST_PURPOSE, PACKAGE_PURPOSE],
                "not_before": "2026-01-01T00:00:00Z",
                "not_after": "2027-01-01T00:00:00Z"
            }
        ]
    })
    .to_string();
    // Duplicate key ids must not shadow revocation or silently restore withdrawn authority.
    assert!(matches!(
        ReleaseTrustRoot::from_json(json.as_bytes()),
        Err(TrustError::DuplicateKeyId(id)) if id == "test-key"
    ));
}

#[test]
fn rejects_unparseable_revocation_metadata() {
    let broken = trust_root_json(true, &["dev"]).replace("2026-06-01T00:00:00Z", "june");
    assert!(matches!(
        ReleaseTrustRoot::from_json(broken.as_bytes()),
        Err(TrustError::InvalidKey { .. })
    ));
}

#[test]
fn rejects_a_malformed_public_key() {
    let bad = trust_root_json(false, &["dev"]).replace(
        &hex::encode(signing_key().verifying_key().to_bytes()),
        "not-hex",
    );
    assert!(matches!(
        ReleaseTrustRoot::from_json(bad.as_bytes()),
        Err(TrustError::InvalidKey { .. })
    ));
}
