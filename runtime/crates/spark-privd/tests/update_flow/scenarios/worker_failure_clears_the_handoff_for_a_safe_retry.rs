#[test]
fn worker_failure_clears_the_handoff_for_a_safe_retry() {
    let h = Harness::new();
    h.stage("lab-0.1.0", b"deb-bytes");
    h.runner.ok(Some(0), "", ""); // schedule
    h.director().schedule("lab-0.1.0").unwrap();
    h.runner.ok(Some(0), "", ""); // docker ps
    h.runner.ok(Some(1), "", "bad signature"); // sealed verifier

    assert_refused(
        h.director().apply_scheduled("lab-0.1.0"),
        "UPDATE_VERIFICATION_FAILED",
    );
    assert!(!h.state.join("scheduled-release-id").exists());
    assert!(h.runner.argv_of("/usr/bin/dpkg").is_empty());
    assert_eq!(
        h.director().update_status("lab-0.1.0").unwrap(),
        Some(RuntimeUpdateStatus::Failed {
            release_id: "lab-0.1.0".into(),
            code: "UPDATE_VERIFICATION_FAILED".into(),
        })
    );
}
