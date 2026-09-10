#[test]
fn os_update_status_without_an_outcome_asks_the_unit_whether_it_is_alive() {
    let root = tempfile::tempdir().unwrap();
    let runner = Arc::new(RecordingRunner::new());
    runner.ok(Some(0), "active\n", "");
    runner.ok(Some(0), "inactive\n", "");
    let backend = DockerBackend::new("docker", false)
        .with_appliance_command_runner(runner.clone())
        .with_system_update_state_root(root.path());
    let job_id = Uuid::new_v4().to_string();

    let starting = backend
        .execute(&PrivilegedOperation::SystemUpdateStatus {
            request_id: Uuid::new_v4(),
            job_id: job_id.clone(),
        })
        .unwrap();
    assert_eq!(starting.code, "system_update.running");
    let lost = backend
        .execute(&PrivilegedOperation::SystemUpdateStatus {
            request_id: Uuid::new_v4(),
            job_id: job_id.clone(),
        })
        .unwrap();
    assert_eq!(lost.code, "UPDATE_SYSTEM_WORKER_LOST");
    let calls = runner.calls();
    assert_eq!(calls.len(), 2);
    assert!(
        calls[0]
            .1
            .contains(&format!("spark-os-update-{job_id}.service")),
        "{:?}",
        calls[0].1
    );

    let error = backend
        .execute(&PrivilegedOperation::SystemUpdateStatus {
            request_id: Uuid::new_v4(),
            job_id: "../etc/passwd".into(),
        })
        .unwrap_err();
    assert!(matches!(error, BackendError::InvalidInput(_)));
}
