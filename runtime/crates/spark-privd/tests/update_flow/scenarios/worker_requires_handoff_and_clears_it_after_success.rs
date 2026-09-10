#[test]
fn worker_requires_handoff_and_clears_it_after_success() {
    let h = Harness::new();
    let staged = h.stage("lab-0.1.0", b"deb-bytes");
    assert_refused(
        h.director().apply_scheduled("lab-0.1.0"),
        "UPDATE_NOT_SCHEDULED",
    );

    h.runner.ok(Some(0), "", ""); // schedule
    h.director().schedule("lab-0.1.0").unwrap();
    let report = h.verify_report(&staged);
    h.runner.ok(Some(0), "", ""); // docker ps
    h.runner.ok(Some(0), &report, ""); // verifier
    h.runner.ok(Some(0), "", ""); // service stop
    h.runner.ok(Some(0), "", ""); // dpkg
    let outcome = h.director().apply_scheduled("lab-0.1.0").unwrap();
    assert!(matches!(outcome, UpdateOutcome::Committed { .. }));
    assert!(!h.state.join("scheduled-release-id").exists());
    assert!(matches!(
        h.director().update_status("lab-0.1.0").unwrap(),
        Some(RuntimeUpdateStatus::Completed { .. })
    ));
}
