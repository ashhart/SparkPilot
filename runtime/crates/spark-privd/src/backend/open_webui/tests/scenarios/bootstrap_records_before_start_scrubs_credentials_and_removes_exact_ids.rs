#[test]
fn bootstrap_records_before_start_scrubs_credentials_and_removes_exact_ids() {
    let fixture = Fixture::new();
    fixture.install();
    let journal = fixture.backend.webui_load().unwrap().unwrap();
    assert_eq!(journal.phase, Phase::Ready);
    assert!(journal.previous.is_none());
    assert!(
        !fixture
            .backend
            .open_webui_root
            .join("bootstrap.env")
            .exists()
    );
    let state = fixture.docker.state.lock().unwrap();
    assert_eq!(state.containers.len(), 1);
    let configuration = state.containers.values().next().unwrap().to_string();
    assert!(!configuration.contains("WEBUI_ADMIN_PASSWORD"));
    assert!(!configuration.contains("a-test-owner-password-42"));
    drop(state);
    assert!(fixture.remove(true).accepted);
    let state = fixture.docker.state.lock().unwrap();
    assert!(state.containers.is_empty());
    assert!(state.volumes.is_empty());
}
