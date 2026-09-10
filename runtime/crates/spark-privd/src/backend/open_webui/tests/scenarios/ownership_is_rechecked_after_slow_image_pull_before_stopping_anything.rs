#[test]
fn ownership_is_rechecked_after_slow_image_pull_before_stopping_anything() {
    let fixture = Fixture::new();
    fixture.install();
    let previous_calls = fixture.docker.state.lock().unwrap().calls.len();
    fixture.docker.state.lock().unwrap().replace_during_pull = true;
    assert!(
        fixture
            .backend
            .execute(&PrivilegedOperation::UpdateOpenWebUi {
                request_id: uuid::Uuid::new_v4(),
                image_digest: image('c')
            })
            .is_err()
    );
    let state = fixture.docker.state.lock().unwrap();
    assert!(state.containers.contains_key(&"e".repeat(64)));
    assert!(
        !state.calls[previous_calls..]
            .iter()
            .any(|args| matches!(args[0].as_str(), "stop" | "rm" | "rename"))
    );
}
