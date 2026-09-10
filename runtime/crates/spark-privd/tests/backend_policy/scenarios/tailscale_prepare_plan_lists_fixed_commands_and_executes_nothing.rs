#[test]
fn tailscale_prepare_plan_lists_fixed_commands_and_executes_nothing() {
    let (paths, _guard) = tailscale_test_paths(true, true);
    let runner = Arc::new(RecordingRunner::new());
    let backend = DockerBackend::new("docker", true)
        .with_appliance_command_runner(runner.clone())
        .with_tailscale_paths(paths);

    let response = backend
        .execute(&PrivilegedOperation::PrepareTailscale {
            request_id: Uuid::new_v4(),
        })
        .unwrap();

    assert_eq!(response.code, "planned");
    assert_eq!(response.details["state"], "unavailable");
    let commands = response.details["commands"].as_array().unwrap();
    assert_eq!(commands[0][0], SYSTEMCTL_BIN);
    assert_eq!(commands[1][0], TAILSCALE_BIN);
    assert_eq!(commands[2][0], TAILSCALE_BIN);
    assert!(runner.calls().is_empty());
}
