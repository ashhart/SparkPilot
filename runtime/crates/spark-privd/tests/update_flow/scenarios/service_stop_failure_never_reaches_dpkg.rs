#[test]
fn service_stop_failure_never_reaches_dpkg() {
    let h = Harness::new();
    let staged = h.stage("lab-0.1.0", b"deb-bytes");
    let report = h.verify_report(&staged);
    h.runner.ok(Some(0), "", ""); // docker ps
    h.runner.ok(Some(0), &report, ""); // verifier
    h.runner.ok(Some(1), "", "spark-privd.service did not stop");

    assert_refused(h.director().install("lab-0.1.0"), "UPDATE_NOT_QUIESCENT");
    assert!(h.runner.argv_of("/usr/bin/dpkg").is_empty());
}
