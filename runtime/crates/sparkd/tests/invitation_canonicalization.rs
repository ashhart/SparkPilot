//! Pin invitation declaration-order JSON with signature:null and unescaped solidus against the shared Rust/Swift canonicalization fixture.

use std::path::PathBuf;

use sparkd::pairing::InvitationPayload;

#[derive(serde::Deserialize)]
struct Fixture {
    cases: Vec<Case>,
}

#[derive(serde::Deserialize)]
struct Case {
    name: String,
    #[allow(dead_code)]
    why: String,
    invitation: serde_json::Value,
    canonical: String,
    canonical_sha256: String,
}

fn load() -> Fixture {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../../contracts/fixtures/pairing-invitation-canonicalization.json");
    let bytes = std::fs::read(&path).expect("invitation canonicalisation fixture is readable");
    serde_json::from_slice(&bytes).expect("invitation canonicalisation fixture parses")
}

#[test]
fn rust_matches_the_shared_invitation_fixture() {
    let fixture = load();
    assert!(!fixture.cases.is_empty(), "fixture has cases");

    for case in &fixture.cases {
        let payload: InvitationPayload = serde_json::from_value(case.invitation.clone())
            .unwrap_or_else(|error| panic!("case {}: invitation must parse: {error}", case.name));
        let canonical = payload
            .canonical_without_signature()
            .unwrap_or_else(|error| panic!("case {}: canonicalisation failed: {error}", case.name));
        let text = String::from_utf8(canonical.clone())
            .unwrap_or_else(|_| panic!("case {}: canonical bytes are UTF-8", case.name));

        assert_eq!(text, case.canonical, "case {}", case.name);
        assert_eq!(
            hex::encode(<sha2::Sha256 as sha2::Digest>::digest(&canonical)),
            case.canonical_sha256,
            "case {}",
            case.name
        );
    }
}

#[test]
fn the_signature_member_is_present_and_null() {
    // Require signature:null because omitting the member changes invitation signing bytes.
    for case in load().cases {
        assert!(
            case.canonical.ends_with(",\"signature\":null}"),
            "case {}: {}",
            case.name,
            case.canonical
        );
    }
}
