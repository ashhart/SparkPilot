#[test]
fn rollback_failure_is_reported_fail_closed() {
    let h = Harness::new();
    let staged = h.stage("lab-0.2.0", b"new-deb");
    let report = h.verify_report(&staged);
    let retained = h.state.join("retained");
    fs::create_dir_all(&retained).unwrap();
    fs::write(retained.join(RETAINED_PACKAGE), b"old-deb").unwrap();
    fs::write(retained.join(RETAINED_MANIFEST), b"{}").unwrap();
    fs::write(retained.join(RETAINED_SIGNATURE), b"sig").unwrap();
    fs::write(h.state.join("current-release-id"), "lab-0.1.0\n").unwrap();

    h.runner.ok(Some(0), "", ""); // docker ps quiet
    h.runner.ok(Some(0), &report, ""); // staged verifier ok
    h.runner.ok(Some(0), "", ""); // services stop
    h.runner.ok(Some(1), "", "gate failed"); // dpkg fails
    let retained_report = serde_json::json!({
        "name": "package", "size": 7, "sha256": sha256(b"old-deb"),
        "signature_key_id": "test", "trust_root_source": "installed",
    })
    .to_string();
    h.runner.ok(Some(0), &retained_report, ""); // retained verifier ok
    h.runner.ok(Some(1), "", "rollback install failed"); // rollback dpkg fails

    let result = h.director().install("lab-0.2.0");
    assert_refused(result, "UPDATE_ROLLBACK_FAILED");
}
