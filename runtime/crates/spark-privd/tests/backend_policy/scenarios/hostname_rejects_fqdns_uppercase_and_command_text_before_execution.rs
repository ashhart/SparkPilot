#[test]
fn hostname_rejects_fqdns_uppercase_and_command_text_before_execution() {
    let runner = Arc::new(RecordingRunner::new());
    let backend = DockerBackend::new("docker", false).with_hostname_command_runner(runner.clone());

    for hostname in [
        "Spark1",
        "spark1.local",
        "spark1; reboot",
        "-spark1",
        "spark1-",
    ] {
        let error = backend
            .execute(&PrivilegedOperation::SetHostname {
                request_id: Uuid::new_v4(),
                hostname: hostname.into(),
            })
            .expect_err("unsafe hostname must be rejected");
        assert!(matches!(error, BackendError::InvalidInput(_)));
    }
    assert!(runner.calls().is_empty());
}
