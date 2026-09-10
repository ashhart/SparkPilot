#[test]
fn no_retained_package_fails_closed_without_claiming_rollback() {
    let h = Harness::new();
    let staged = h.stage("lab-0.2.0", b"new-deb");
    let report = h.verify_report(&staged);
    h.runner.ok(Some(0), "", ""); // docker ps quiet
    h.runner.ok(Some(0), &report, ""); // staged verifier ok
    h.runner.ok(Some(0), "", ""); // services stop
    h.runner.ok(Some(1), "", "post-install health gate failed"); // dpkg fails

    let outcome = h.director().install("lab-0.2.0").unwrap();
    match &outcome {
        UpdateOutcome::DataRestoredPackageManual {
            release_id,
            evidence,
        } => {
            assert_eq!(release_id, "lab-0.2.0");
            assert!(!evidence.is_empty(), "evidence paths are reported");
        }
        other => panic!("expected manual outcome, got {other:?}"),
    }
    // Manual recovery must never report successful rollback.
    assert!(!outcome.accepted());
    assert_ne!(outcome.code(), "update.rolled_back");
    
    assert_eq!(h.runner.argv_of("/usr/bin/dpkg").len(), 1);
}
