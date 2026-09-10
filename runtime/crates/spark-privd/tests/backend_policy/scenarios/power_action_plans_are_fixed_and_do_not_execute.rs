#[test]
fn power_action_plans_are_fixed_and_do_not_execute() {
    let runner = Arc::new(RecordingRunner::new());
    let backend = DockerBackend::new("docker", true).with_power_command_runner(runner.clone());

    for (operation, expected_args) in [
        (
            PrivilegedOperation::Reboot {
                request_id: Uuid::new_v4(),
            },
            vec!["reboot", "--no-block"],
        ),
        (
            PrivilegedOperation::Shutdown {
                request_id: Uuid::new_v4(),
            },
            vec!["poweroff", "--no-block"],
        ),
    ] {
        let response = backend.execute(&operation).unwrap();
        assert_eq!(response.code, "planned");
        assert_eq!(response.details["program"], SYSTEMCTL_BIN);
        assert_eq!(response.details["args"], serde_json::json!(expected_args));
    }
    assert!(runner.calls().is_empty());
}
