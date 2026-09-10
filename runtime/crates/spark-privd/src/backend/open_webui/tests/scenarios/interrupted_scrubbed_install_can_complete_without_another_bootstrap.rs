#[test]
fn interrupted_scrubbed_install_can_complete_without_another_bootstrap() {
    let fixture = Fixture::new();
    fixture.install();
    let mut journal = fixture.backend.webui_load().unwrap().unwrap();
    journal.phase = Phase::Installing;
    fixture.backend.webui_save(&journal).unwrap();
    let count = fixture
        .docker
        .state
        .lock()
        .unwrap()
        .calls
        .iter()
        .filter(|args| args[0] == "create")
        .count();
    assert!(fixture.repair().accepted);
    assert_eq!(
        fixture.backend.webui_load().unwrap().unwrap().phase,
        Phase::Ready
    );
    assert_eq!(
        fixture
            .docker
            .state
            .lock()
            .unwrap()
            .calls
            .iter()
            .filter(|args| args[0] == "create")
            .count(),
        count
    );
}
