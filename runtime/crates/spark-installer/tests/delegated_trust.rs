use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use serde_json::Value;
use spark_installer::trust::ReleaseTrustRoot;
use time::{OffsetDateTime, format_description::well_known::Rfc3339};

fn fixture() -> Value {
    serde_json::from_str(include_str!(
        "../../../../contracts/fixtures/release-delegation.json"
    ))
    .unwrap()
}

#[test]
fn offline_delegation_verifies_production_manifest_and_package() {
    let f = fixture();
    let root = ReleaseTrustRoot::from_json(f["trust"].to_string().as_bytes()).unwrap();
    let at = OffsetDateTime::parse(f["at"].as_str().unwrap(), &Rfc3339).unwrap();
    let verified = root
        .verify_manifest(f["manifest"].to_string().as_bytes(), at)
        .unwrap();
    root.verify_detached(
        &verified.key_id,
        f["package"].as_str().unwrap().as_bytes(),
        &URL_SAFE_NO_PAD
            .decode(f["package_signature"].as_str().unwrap())
            .unwrap(),
        at,
        "stable",
    )
    .unwrap();
}

#[test]
fn offline_delegation_rejects_unsigned_policy_changes() {
    let f = fixture();
    let at = OffsetDateTime::parse(f["at"].as_str().unwrap(), &Rfc3339).unwrap();
    for (pointer, replacement) in [
        (
            "/keys/0/not_after",
            serde_json::json!("2028-01-01T00:00:00Z"),
        ),
        ("/keys/0/public_key", serde_json::json!("aa".repeat(32))),
        ("/delegation/version", serde_json::json!(2)),
        (
            "/delegation/not_after",
            serde_json::json!("2028-01-01T00:00:00Z"),
        ),
        ("/minimum_delegation_version", serde_json::json!(2)),
        (
            "/root_keys/0/revoked_at",
            serde_json::json!("2026-02-01T00:00:00Z"),
        ),
    ] {
        let mut trust = f["trust"].clone();
        if pointer.ends_with("revoked_at") {
            trust["root_keys"][0]["revoked_at"] = replacement;
        } else {
            *trust.pointer_mut(pointer).unwrap() = replacement;
        }
        let verdict = ReleaseTrustRoot::from_json(trust.to_string().as_bytes())
            .and_then(|root| root.verify_manifest(f["manifest"].to_string().as_bytes(), at));
        assert!(verdict.is_err(), "accepted {pointer}");
    }
}

#[test]
fn offline_delegation_matches_shared_adversarial_cases() {
    let f = fixture();
    for case in f["cases"].as_array().unwrap() {
        let root = ReleaseTrustRoot::from_json(case["trust"].to_string().as_bytes());
        let at = OffsetDateTime::parse(case["at"].as_str().unwrap(), &Rfc3339).unwrap();
        let manifest = root.as_ref().ok().and_then(|root| {
            root.verify_manifest(case["manifest"].to_string().as_bytes(), at)
                .ok()
        });
        assert_eq!(
            manifest.is_some(),
            case["accept_manifest"].as_bool().unwrap(),
            "{}",
            case["name"]
        );
        let package = root.as_ref().ok().and_then(|root| {
            root.verify_detached(
                "fixture-online",
                f["package"].as_str().unwrap().as_bytes(),
                &URL_SAFE_NO_PAD
                    .decode(f["package_signature"].as_str().unwrap())
                    .unwrap(),
                at,
                case["manifest"]["channel"].as_str().unwrap(),
            )
            .ok()
        });
        if manifest.is_some() {
            assert_eq!(
                package.is_some(),
                case["accept_package"].as_bool().unwrap(),
                "{}",
                case["name"]
            );
        }
    }
}
