#[test]
fn hostname_plan_and_execution_use_only_validated_hostnamectl_argv() {
    let request_id = Uuid::new_v4();
    let operation = PrivilegedOperation::SetHostname {
        request_id,
        hostname: "spark1".into(),
    };

    let planned_runner = Arc::new(RecordingRunner::new());
    let planned = DockerBackend::new("docker", true)
        .with_hostname_command_runner(planned_runner.clone())
        .execute(&operation)
        .unwrap();
    assert_eq!(planned.code, "planned");
    assert_eq!(planned.details["program"], HOSTNAMECTL_BIN);
    assert_eq!(
        planned.details["args"],
        serde_json::json!(["set-hostname", "spark1"])
    );
    assert!(planned_runner.calls().is_empty());

    let runner = Arc::new(RecordingRunner::new());
    runner.ok(Some(0), "", "");
    let changed = DockerBackend::new("docker", false)
        .with_hostname_command_runner(runner.clone())
        .execute(&operation)
        .unwrap();
    assert_eq!(changed.code, "hostname_changed");
    assert_eq!(changed.details["hostname"], "spark1");
    assert_eq!(
        runner.calls(),
        vec![(
            HOSTNAMECTL_BIN.into(),
            vec!["set-hostname".into(), "spark1".into()],
        )]
    );
}
