#[test]
fn identical_image_and_copied_labels_do_not_adopt_a_replacement_id() {
    let fixture = Fixture::new();
    fixture.install();
    let id = fixture.docker.current_id();
    let mut state = fixture.docker.state.lock().unwrap();
    let mut impostor = state.containers.remove(&id).unwrap();
    let foreign = "f".repeat(64);
    impostor["Id"] = json!(foreign);
    state.containers.insert(foreign.clone(), impostor);
    let before = state.calls.len();
    drop(state);
    assert_eq!(fixture.update().code, "OPEN_WEBUI_OWNERSHIP_UNVERIFIED");
    assert_eq!(fixture.remove(true).code, "OPEN_WEBUI_OWNERSHIP_UNVERIFIED");
    assert_eq!(fixture.repair().code, "OPEN_WEBUI_OWNERSHIP_UNVERIFIED");
    let state = fixture.docker.state.lock().unwrap();
    assert!(state.containers.contains_key(&foreign));
    assert!(
        state.calls[before..]
            .iter()
            .all(|args| args.get(1).is_some_and(|arg| arg == "inspect"))
    );
}
