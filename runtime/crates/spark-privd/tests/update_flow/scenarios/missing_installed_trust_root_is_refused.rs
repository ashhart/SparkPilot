#[test]
fn missing_installed_trust_root_is_refused() {
    let h = Harness::new();
    let _staged = h.stage("lab-0.1.0", b"deb-bytes");
    fs::remove_file(&h.trust).unwrap();
    h.runner.ok(Some(0), "", "");
    let result = h.director().install("lab-0.1.0");
    assert_refused(result, "UPDATE_NO_TRUST_ROOT");
}
