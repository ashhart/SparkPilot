#[test]
fn symlinked_staged_package_is_refused() {
    let h = Harness::new();
    let staged = h.stage("lab-0.1.0", b"deb-bytes");
    let target = h.dir.path().join("outside");
    fs::write(&target, b"escape").unwrap();
    fs::remove_file(staged.join(STAGED_PACKAGE)).unwrap();
    std::os::unix::fs::symlink(&target, staged.join(STAGED_PACKAGE)).unwrap();
    h.runner.ok(Some(0), "", "");
    let result = h.director().install("lab-0.1.0");
    assert_refused(result, "UPDATE_STAGING_INVALID");
}
