#[test]
fn retry_of_current_release_is_an_idempotent_no_op() {
    let h = Harness::new();
    let staged = h.stage("lab-0.1.0", b"deb-bytes");
    let report = h.verify_report(&staged);
    h.runner.ok(Some(0), "", "");
    h.runner.ok(Some(0), &report, "");
    h.runner.ok(Some(0), "", "");
    h.runner.ok(Some(0), "", "");
    let director = h.director();
    director.install("lab-0.1.0").unwrap();

    // Second request of the same release id: committed marker short-circuits.
    h.runner.calls.lock().clear();
    h.runner.results.lock().clear();
    let outcome = director.install("lab-0.1.0").unwrap();
    assert!(matches!(outcome, UpdateOutcome::AlreadyCommitted { .. }));
    assert!(
        h.runner.argv_of("/usr/bin/dpkg").is_empty(),
        "no dpkg on retry"
    );
    assert!(
        h.runner
            .argv_of("/usr/lib/spark-runtime/spark-installer")
            .is_empty()
    );
}
