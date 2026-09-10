#[test]
fn sealed_digest_mismatch_is_refused() {
    let h = Harness::new();
    let _staged = h.stage("lab-0.1.0", b"deb-bytes");
    // Reject a verifier digest that disagrees with the sealed package bytes.
    let lying = serde_json::json!({
        "name": "package",
        "size": 3,
        "sha256": sha256(b"different"),
        "signature_key_id": "test",
        "trust_root_source": "installed",
    })
    .to_string();
    h.runner.ok(Some(0), "", ""); // docker ps
    h.runner.ok(Some(0), &lying, ""); // verifier lies about the digest
    let result = h.director().install("lab-0.1.0");
    assert_refused(result, "UPDATE_STAGING_INVALID sealed package digest");
    assert!(h.runner.argv_of("/usr/bin/dpkg").is_empty());
}
