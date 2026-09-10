/// Observe existing workloads with fixed read-only arguments and a projection that excludes sensitive fields.
#[test]
fn observing_workloads_runs_one_fixed_read_only_projection() {
    let runner = Arc::new(RecordingRunner::new());
    runner.ok(Some(0), "", "");
    let backend = DockerBackend::new("docker", false).with_appliance_command_runner(runner.clone());

    let response = backend
        .execute(&PrivilegedOperation::InventoryWorkloads {
            request_id: Uuid::new_v4(),
        })
        .expect("observation");

    assert!(response.accepted);
    let argv = runner.argv_of("docker");
    assert_eq!(argv.len(), 1, "one command only: {argv:?}");
    assert_eq!(
        argv[0],
        vec![
            "ps".to_owned(),
            "--all".to_owned(),
            "--no-trunc".to_owned(),
            "--format".to_owned(),
            "{{.ID}}\t{{.Names}}\t{{.State}}\t{{.Image}}\t{{.Ports}}".to_owned(),
        ]
    );
    for forbidden in [".Command", ".Labels", ".Mounts", "--filter", "inspect"] {
        assert!(
            !argv[0].iter().any(|argument| argument.contains(forbidden)),
            "{forbidden} must not appear in a read-only observation: {argv:?}"
        );
    }
    // No mutating verb reached the container runtime.
    for (_, args) in runner.calls() {
        for verb in ["run", "stop", "rm", "kill", "restart", "exec", "prune"] {
            assert_ne!(args.first().map(String::as_str), Some(verb));
        }
    }
}
