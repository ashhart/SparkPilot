#[test]
fn interrupted_promotion_finishes_after_previous_container_was_removed() {
    let fixture = Fixture::new();
    fixture.install();
    let mut journal = fixture.backend.webui_load().unwrap().unwrap();
    let previous = journal.current.take().unwrap();
    journal.previous = Some(previous.clone());
    journal.phase = Phase::Updating;
    fixture.backend.webui_save(&journal).unwrap();
    fixture
        .backend
        .webui_command(&["stop", "--time=20", &previous.id])
        .unwrap();
    fixture
        .backend
        .webui_command(&["rename", &previous.id, "retained-prior"])
        .unwrap();
    fixture
        .backend
        .webui_create(&mut journal, &image('c'), false)
        .unwrap();
    journal.phase = Phase::Promoting;
    fixture.backend.webui_save(&journal).unwrap();
    fixture.backend.webui_remove_exact(&previous).unwrap();
    let replacement = fixture.docker.current_id();
    assert!(fixture.repair().accepted);
    assert_eq!(fixture.docker.current_id(), replacement);
    assert_eq!(
        fixture.backend.webui_load().unwrap().unwrap().phase,
        Phase::Ready
    );
}
