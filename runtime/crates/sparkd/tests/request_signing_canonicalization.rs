//! Pin SPARK2's normative seven-field §58.3 form, including final device id, against the shared Rust/Swift fixture.

const SIGNING_NODE_ID: uuid::Uuid = uuid::Uuid::from_u128(2);

use std::path::PathBuf;

use sparkd::auth::canonical;
use sparkd::crypto::sha256_hex;

fn fixture_path() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../../contracts/fixtures/request-signing-canonicalization.json")
}

#[test]
fn the_runtime_reproduces_every_shared_canonical_case() {
    let text = std::fs::read_to_string(fixture_path()).expect("signing fixture");
    let document: serde_json::Value = serde_json::from_str(&text).expect("fixture json");
    let cases = document["cases"].as_array().expect("cases");
    assert!(!cases.is_empty(), "the fixture must carry cases");

    for case in cases {
        let name = case["name"].as_str().unwrap();
        let request = &case["request"];
        let body = request["body"].as_str().unwrap();
        let digest = sha256_hex(body.as_bytes());
        assert_eq!(
            digest,
            case["content_sha256"].as_str().unwrap(),
            "{name}: the body digest must match the fixture"
        );

        let produced = canonical(
            request["method"].as_str().unwrap(),
            request["path_and_query"].as_str().unwrap(),
            request["timestamp"].as_str().unwrap(),
            request["nonce"].as_str().unwrap(),
            &digest,
            &uuid::Uuid::parse_str(request["device_id"].as_str().unwrap()).unwrap(),
            &uuid::Uuid::parse_str(request["node_id"].as_str().unwrap()).unwrap(),
        );
        assert_eq!(
            produced,
            case["canonical"].as_str().unwrap(),
            "{name}: canonical bytes differ from the shared fixture"
        );
        assert_eq!(
            sha256_hex(produced.as_bytes()),
            case["canonical_sha256"].as_str().unwrap(),
            "{name}: canonical digest differs"
        );
    }
}

#[test]
fn the_device_id_line_is_what_binds_a_signature_to_one_device() {
    // Require the device-id field omitted by the older six-line narrative form so signatures cannot be rebound through device headers.
    let first = uuid::Uuid::parse_str("ca890ed7-7c8c-4b2c-9218-b77ef24f569a").unwrap();
    let second = uuid::Uuid::parse_str("3b6e5c2a-1d4f-4a8b-9c0d-2e5f7a8b9c0d").unwrap();
    let digest = sha256_hex(b"");
    let a = canonical(
        "GET",
        "/api/v1/status",
        "2026-08-27T10:05:00Z",
        "n",
        &digest,
        &first,
        &SIGNING_NODE_ID,
    );
    let b = canonical(
        "GET",
        "/api/v1/status",
        "2026-08-27T10:05:00Z",
        "n",
        &digest,
        &second,
        &SIGNING_NODE_ID,
    );
    assert_ne!(
        a, b,
        "two devices must not produce the same canonical bytes"
    );
    assert_eq!(a.lines().count(), 8, "the normative form has eight lines");
    assert_eq!(a.lines().next(), Some("SPARK2"));
    assert_eq!(a.lines().nth(6), Some(first.to_string().as_str()));
}
