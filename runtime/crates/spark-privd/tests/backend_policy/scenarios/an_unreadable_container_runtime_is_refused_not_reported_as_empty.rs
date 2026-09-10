/// A container runtime that did not answer has not told us the host is idle.
#[test]
fn an_unreadable_container_runtime_is_refused_not_reported_as_empty() {
    let runner = Arc::new(RecordingRunner::new());
    runner.ok(Some(1), "", "permission denied while trying to connect");
    let backend = DockerBackend::new("docker", false).with_appliance_command_runner(runner.clone());

    let response = backend
        .execute(&PrivilegedOperation::InventoryWorkloads {
            request_id: Uuid::new_v4(),
        })
        .expect("observation");

    assert!(!response.accepted);
    assert_eq!(response.code, "workload_inventory_unavailable");
    assert!(response.details.is_null());
    // The helper's own stderr is not forwarded: it can name paths and users.
    assert!(!response.message.contains("permission denied"));
}
