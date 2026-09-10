#[test]
fn missing_receipt_and_changed_privilege_fail_before_any_mutation() {
    let fixture = Fixture::new();
    fixture.install();
    let journal = fs::read(&fixture.docker.journal).unwrap();
    fs::remove_file(&fixture.docker.journal).unwrap();
    assert_eq!(fixture.remove(true).code, "OPEN_WEBUI_OWNERSHIP_UNVERIFIED");
    fs::write(&fixture.docker.journal, journal).unwrap();
    fs::set_permissions(&fixture.docker.journal, fs::Permissions::from_mode(0o600)).unwrap();
    let id = fixture.docker.current_id();
    fixture
        .docker
        .state
        .lock()
        .unwrap()
        .containers
        .get_mut(&id)
        .unwrap()["HostConfig"]["Privileged"] = json!(true);
    assert_eq!(fixture.repair().code, "OPEN_WEBUI_OWNERSHIP_UNVERIFIED");
}
