#[test]
fn failed_update_restores_exact_previous_container_and_owned_data() {
    let fixture = Fixture::new();
    fixture.install();
    let before = fixture.docker.current_id();
    fixture.health.lock().unwrap().extend([false, true]);
    let response = fixture.update();
    assert!(!response.accepted);
    assert_eq!(response.code, "OPEN_WEBUI_UPDATE_ROLLED_BACK");
    assert_eq!(fixture.docker.current_id(), before);
    assert_eq!(
        fixture.backend.webui_load().unwrap().unwrap().phase,
        Phase::Ready
    );
    assert_eq!(fixture.docker.state.lock().unwrap().volumes.len(), 1);
}
