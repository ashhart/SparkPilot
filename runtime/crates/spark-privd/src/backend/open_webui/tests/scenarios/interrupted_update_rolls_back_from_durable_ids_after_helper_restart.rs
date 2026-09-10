#[test]
fn interrupted_update_rolls_back_from_durable_ids_after_helper_restart() {
    let fixture = Fixture::new();
    fixture.install();
    let mut journal = fixture.backend.webui_load().unwrap().unwrap();
    let id = journal.current.as_ref().unwrap().id.clone();
    journal.previous = journal.current.take();
    journal.phase = Phase::Updating;
    fixture.backend.webui_save(&journal).unwrap();
    fixture
        .backend
        .webui_command(&["stop", "--time=20", &id])
        .unwrap();
    fixture
        .backend
        .webui_command(&["rename", &id, "retained-prior"])
        .unwrap();
    assert!(fixture.repair().accepted);
    assert_eq!(fixture.docker.current_id(), id);
    assert_eq!(
        fixture.backend.webui_load().unwrap().unwrap().phase,
        Phase::Ready
    );
}
