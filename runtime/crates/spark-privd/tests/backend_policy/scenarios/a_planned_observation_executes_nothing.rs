#[test]
fn a_planned_observation_executes_nothing() {
    let runner = Arc::new(RecordingRunner::new());
    let backend = DockerBackend::new("docker", true).with_appliance_command_runner(runner.clone());

    let response = backend
        .execute(&PrivilegedOperation::InventoryWorkloads {
            request_id: Uuid::new_v4(),
        })
        .expect("plan");

    assert_eq!(response.code, "planned");
    assert!(runner.calls().is_empty());
}
