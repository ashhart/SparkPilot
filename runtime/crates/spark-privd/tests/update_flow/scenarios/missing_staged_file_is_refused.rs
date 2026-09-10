#[test]
fn missing_staged_file_is_refused() {
    let h = Harness::new();
    let staged = h.stage("lab-0.1.0", b"deb-bytes");
    fs::remove_file(staged.join(STAGED_SIGNATURE)).unwrap();
    h.runner.ok(Some(0), "", "");
    let result = h.director().install("lab-0.1.0");
    assert_refused(result, "UPDATE_STAGING_INVALID");
}
