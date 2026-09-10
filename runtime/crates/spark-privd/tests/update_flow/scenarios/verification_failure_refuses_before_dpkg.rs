#[test]
fn verification_failure_refuses_before_dpkg() {
    let h = Harness::new();
    let _staged = h.stage("lab-0.1.0", b"deb-bytes");
    h.runner.ok(Some(0), "", ""); // docker ps quiet
    h.runner.ok(Some(1), "", "bad signature"); // verifier refuses

    let result = h.director().install("lab-0.1.0");
    assert_refused(result, "UPDATE_VERIFICATION_FAILED");
    assert!(
        h.runner.argv_of("/usr/bin/dpkg").is_empty(),
        "no install after verification failure"
    );
}
