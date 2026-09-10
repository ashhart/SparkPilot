#[test]
fn repair_refuses_stops_restarts_once_and_persists_cooldown() {
    let fixture = Fixture::new();
    fixture.install();
    let id = fixture.docker.current_id();
    fixture
        .docker
        .state
        .lock()
        .unwrap()
        .containers
        .get_mut(&id)
        .unwrap()["State"]["Running"] = json!(false);
    assert_eq!(fixture.repair().code, "OPEN_WEBUI_INTENTIONALLY_STOPPED");
    fixture
        .docker
        .state
        .lock()
        .unwrap()
        .containers
        .get_mut(&id)
        .unwrap()["State"]["Running"] = json!(true);
    fixture.health.lock().unwrap().extend([false, false, false]);
    assert_eq!(fixture.repair().code, "OPEN_WEBUI_REPAIR_FAILED");
    assert_eq!(fixture.repair().code, "OPEN_WEBUI_REPAIR_COOLDOWN");
    assert_eq!(
        fixture
            .docker
            .state
            .lock()
            .unwrap()
            .calls
            .iter()
            .filter(|args| args[0] == "restart")
            .count(),
        1
    );
    assert!(
        fixture
            .backend
            .webui_load()
            .unwrap()
            .unwrap()
            .last_repair_epoch
            > 0
    );
}
