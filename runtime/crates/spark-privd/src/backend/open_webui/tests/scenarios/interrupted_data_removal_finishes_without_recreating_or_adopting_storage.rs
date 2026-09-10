#[test]
fn interrupted_data_removal_finishes_without_recreating_or_adopting_storage() {
    let fixture = Fixture::new();
    fixture.install();
    let mut journal = fixture.backend.webui_load().unwrap().unwrap();
    fixture
        .backend
        .webui_remove_exact(journal.current.as_ref().unwrap())
        .unwrap();
    journal.current = None;
    journal.phase = Phase::Removing;
    journal.erase_data = true;
    fixture.backend.webui_save(&journal).unwrap();
    fixture.docker.state.lock().unwrap().volumes.clear();
    assert!(fixture.remove(true).accepted);
    assert!(
        fixture
            .backend
            .webui_load()
            .unwrap()
            .unwrap()
            .volume
            .is_none()
    );
}
