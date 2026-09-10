#[test]
fn power_action_failure_is_reported_without_claiming_acceptance() {
    let runner = Arc::new(RecordingRunner::new());
    runner.ok(Some(1), "", "systemd refused request");
    let backend = DockerBackend::new("docker", false).with_power_command_runner(runner);

    let error = backend
        .execute(&PrivilegedOperation::Shutdown {
            request_id: Uuid::new_v4(),
        })
        .expect_err("a failed poweroff must be surfaced");

    assert!(matches!(error, BackendError::Failure(_)));
    assert!(error.to_string().contains("systemd refused request"));
}
