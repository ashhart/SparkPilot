#[test]
fn tampered_or_symlinked_root_receipt_is_not_trusted() {
    let fixture = Fixture::new();
    fixture.install();
    fs::set_permissions(&fixture.docker.journal, fs::Permissions::from_mode(0o666)).unwrap();
    assert_eq!(fixture.remove(true).code, "OPEN_WEBUI_OWNERSHIP_UNVERIFIED");
    fs::remove_file(&fixture.docker.journal).unwrap();
    std::os::unix::fs::symlink("/dev/null", &fixture.docker.journal).unwrap();
    assert_eq!(fixture.repair().code, "OPEN_WEBUI_OWNERSHIP_UNVERIFIED");
}
