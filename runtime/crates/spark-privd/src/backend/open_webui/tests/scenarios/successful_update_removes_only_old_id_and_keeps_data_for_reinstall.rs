#[test]
fn successful_update_removes_only_old_id_and_keeps_data_for_reinstall() {
    let fixture = Fixture::new();
    fixture.install();
    let before = fixture.docker.current_id();
    assert!(fixture.update().accepted);
    let after = fixture.docker.current_id();
    assert_ne!(before, after);
    assert!(
        !fixture
            .docker
            .state
            .lock()
            .unwrap()
            .containers
            .contains_key(&before)
    );
    let volume = fixture
        .backend
        .webui_load()
        .unwrap()
        .unwrap()
        .volume
        .unwrap()
        .name;
    assert!(fixture.remove(false).accepted);
    fixture.install();
    assert_eq!(
        fixture
            .backend
            .webui_load()
            .unwrap()
            .unwrap()
            .volume
            .unwrap()
            .name,
        volume
    );
}
