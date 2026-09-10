/// Count unreadable runtime rows so successful but unsupported output cannot imply an idle host.
#[test]
fn rows_this_build_cannot_read_are_counted_rather_than_silently_dropped() {
    let runner = Arc::new(RecordingRunner::new());
    runner.ok(
        Some(0),
        "CONTAINER ID   IMAGE   COMMAND   STATUS\nsome other runtime output\n",
        "",
    );
    let backend = DockerBackend::new("docker", false).with_appliance_command_runner(runner.clone());

    let response = backend
        .execute(&PrivilegedOperation::InventoryWorkloads {
            request_id: Uuid::new_v4(),
        })
        .expect("observation");

    let observed: spark_privd::workloads::ObservedWorkloads =
        serde_json::from_value(response.details).expect("decode");
    assert!(observed.containers.is_empty());
    assert_eq!(observed.unreadable_lines, 2);
    assert!(!observed.truncated, "nothing was dropped for space");
}
