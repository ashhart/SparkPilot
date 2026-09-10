//! Pin Rust to the release canonicalization fixture shared with Python and Swift so signatures remain interoperable.

use std::path::PathBuf;

use spark_installer::manifest::ReleaseManifest;

#[derive(serde::Deserialize)]
struct Fixture {
    cases: Vec<Case>,
}

#[derive(serde::Deserialize)]
struct Case {
    name: String,
    why: String,
    manifest: serde_json::Value,
    canonical: String,
    canonical_sha256: String,
}

fn fixture_path() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../../contracts/fixtures/release-manifest-canonicalization.json")
}

fn load() -> Fixture {
    let bytes = std::fs::read(fixture_path()).expect("canonicalisation fixture is readable");
    serde_json::from_slice(&bytes).expect("canonicalisation fixture parses")
}

#[test]
fn rust_matches_the_shared_canonicalisation_fixture() {
    let fixture = load();
    assert!(!fixture.cases.is_empty(), "fixture has cases");

    for case in &fixture.cases {
        let manifest = ReleaseManifest::parse(case.manifest.to_string().as_bytes())
            .unwrap_or_else(|error| panic!("case {}: manifest must parse: {error}", case.name));
        let canonical = manifest
            .canonical_bytes()
            .unwrap_or_else(|error| panic!("case {}: canonicalisation failed: {error}", case.name));

        assert_eq!(
            String::from_utf8(canonical.clone()).expect("canonical bytes are UTF-8"),
            case.canonical,
            "case {} disagrees with the shared fixture.\n{}",
            case.name,
            case.why
        );

        use sha2::{Digest, Sha256};
        assert_eq!(
            hex::encode(Sha256::digest(&canonical)),
            case.canonical_sha256,
            "case {}: digest of canonical bytes",
            case.name
        );
    }
}

#[test]
fn optional_shape_and_key_order_do_not_change_the_signed_bytes() {
    // Explicit null, omitted optionals, reordered keys and signed forms of the same manifest must canonicalize identically.
    let fixture = load();
    let equivalent: Vec<&Case> = fixture
        .cases
        .iter()
        .filter(|case| {
            matches!(
                case.name.as_str(),
                "explicit_null_optional"
                    | "omitted_optionals"
                    | "reordered_keys"
                    | "signature_member_is_excluded"
            )
        })
        .collect();
    assert_eq!(
        equivalent.len(),
        4,
        "all four equivalence cases are present"
    );

    let mut produced = std::collections::BTreeSet::new();
    for case in equivalent {
        let manifest = ReleaseManifest::parse(case.manifest.to_string().as_bytes()).unwrap();
        produced.insert(manifest.canonical_bytes().unwrap());
    }
    assert_eq!(
        produced.len(),
        1,
        "the four equivalent manifests produced {} distinct canonical forms",
        produced.len()
    );
}

#[test]
fn canonical_bytes_never_contain_a_null_or_an_escaped_solidus() {
    let fixture = load();
    for case in &fixture.cases {
        let manifest = ReleaseManifest::parse(case.manifest.to_string().as_bytes()).unwrap();
        let canonical = String::from_utf8(manifest.canonical_bytes().unwrap()).unwrap();
        assert!(
            !canonical.contains(":null"),
            "case {}: null members must be dropped, not encoded",
            case.name
        );
        assert!(
            !canonical.contains("\\/"),
            "case {}: the solidus must never be escaped",
            case.name
        );
        assert!(
            !canonical.contains("\"signature\":"),
            "case {}: the signature member must be excluded",
            case.name
        );
    }
}
