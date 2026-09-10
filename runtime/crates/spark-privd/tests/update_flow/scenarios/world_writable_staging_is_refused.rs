#[test]
fn world_writable_staging_is_refused() {
    let h = Harness::new();
    let staged = h.stage("lab-0.1.0", b"deb-bytes");
    fs::set_permissions(&staged, fs::Permissions::from_mode(0o777)).unwrap();
    h.runner.ok(Some(0), "", "");
    let result = h.director().install("lab-0.1.0");
    assert_refused(result, "UPDATE_STAGING_INVALID");
}
