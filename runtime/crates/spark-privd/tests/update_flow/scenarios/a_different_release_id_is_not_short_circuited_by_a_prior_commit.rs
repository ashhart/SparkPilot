#[test]
fn a_different_release_id_is_not_short_circuited_by_a_prior_commit() {
    for (previous, next) in [
        ("lab-0.1.0", "lab-0.2.0"),
        ("dev-0.1.13", "dev-0.1.13-0qa20260907.3"),
        ("dev-0.1.13-0qa20260907.2", "dev-0.1.13-0qa20260907.3"),
    ] {
        let h = Harness::new();
        let staged = h.stage(previous, b"deb-a");
        let report = h.verify_report(&staged);
        h.runner.ok(Some(0), "", "");
        h.runner.ok(Some(0), &report, "");
        h.runner.ok(Some(0), "", "");
        h.runner.ok(Some(0), "", "");
        h.director().install(previous).unwrap();
        // Reset the observation window; only the second apply's calls count.
        h.runner.calls.lock().clear();
        h.runner.results.lock().clear();

        let staged_b = h.stage(next, b"deb-b");
        let report_b = h.verify_report(&staged_b);
        h.runner.ok(Some(0), "", "");
        h.runner.ok(Some(0), &report_b, "");
        h.runner.ok(Some(0), "", "");
        h.runner.ok(Some(0), "", "");
        let outcome = h.director().install(next).unwrap();
        assert!(matches!(outcome, UpdateOutcome::Committed { .. }));
        assert_eq!(h.runner.argv_of("/usr/bin/dpkg").len(), 1);
        assert!(matches!(
            h.director().install(next).unwrap(),
            UpdateOutcome::AlreadyCommitted { .. }
        ));
        assert_eq!(h.runner.argv_of("/usr/bin/dpkg").len(), 1);
    }
}
