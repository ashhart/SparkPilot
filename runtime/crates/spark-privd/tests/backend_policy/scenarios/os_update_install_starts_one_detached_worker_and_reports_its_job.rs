#[test]
fn os_update_install_starts_one_detached_worker_and_reports_its_job() {
    let runner = Arc::new(RecordingRunner::new());
    runner.ok(Some(0), "", "");
    let backend = DockerBackend::new("docker", false).with_appliance_command_runner(runner.clone());
    let request_id = Uuid::new_v4();

    let response = backend
        .execute(&PrivilegedOperation::InstallSystemUpdates {
            request_id,
            system_packages: true,
            firmware: true,
        })
        .unwrap();

    assert_eq!(response.code, "system_update.scheduled");
    assert_eq!(response.details["job_id"], request_id.to_string());
    let calls = runner.calls();
    assert_eq!(
        calls.len(),
        1,
        "the helper starts the worker and nothing else"
    );
    let (program, argv) = &calls[0];
    assert_eq!(program, SYSTEMD_RUN_BIN);
    let separator = argv
        .iter()
        .position(|arg| arg == "--")
        .expect("argv separator");
    assert_eq!(
        &argv[separator + 1..],
        &[
            SPARK_UPDATER_BIN.to_owned(),
            "os-update".to_owned(),
            "--job-id".to_owned(),
            request_id.to_string(),
            "--system-packages".to_owned(),
            "--firmware".to_owned(),
        ]
    );
    assert!(argv.contains(&"--collect".to_owned()));
    assert!(
        !argv.contains(&"--wait".to_owned()),
        "the worker is detached"
    );
    assert!(
        argv.iter()
            .all(|arg| !arg.contains("sh -c") && !arg.contains(';'))
    );
    let unit = argv
        .iter()
        .position(|arg| arg == "--unit")
        .map(|index| argv[index + 1].clone())
        .expect("a named unit");
    assert_eq!(unit, format!("spark-os-update-{request_id}"));
}
