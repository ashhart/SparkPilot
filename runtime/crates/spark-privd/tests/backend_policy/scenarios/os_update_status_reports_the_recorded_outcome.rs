#[test]
fn os_update_status_reports_the_recorded_outcome() {
    use std::os::unix::fs::PermissionsExt;

    let root = tempfile::tempdir().unwrap();
    let runner = Arc::new(RecordingRunner::new());
    let backend = DockerBackend::new("docker", false)
        .with_appliance_command_runner(runner.clone())
        .with_system_update_state_root(root.path());
    let job_id = Uuid::new_v4().to_string();
    let path = root.path().join(format!("{job_id}.json"));
    for (state, expected) in [
        ("running", "system_update.running"),
        ("succeeded", "system_update.succeeded"),
        ("failed", "system_update.failed"),
    ] {
        std::fs::write(
            &path,
            serde_json::json!({ "job_id": job_id, "state": state, "steps": [] }).to_string(),
        )
        .unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)).unwrap();
        let response = backend
            .execute(&PrivilegedOperation::SystemUpdateStatus {
                request_id: Uuid::new_v4(),
                job_id: job_id.clone(),
            })
            .unwrap();
        assert_eq!(response.code, expected);
        assert_eq!(response.details["state"], state);
    }
    assert!(
        runner.calls().is_empty(),
        "a recorded outcome needs no unit query"
    );

    // A world-readable outcome is not trusted.
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o644)).unwrap();
    let error = backend
        .execute(&PrivilegedOperation::SystemUpdateStatus {
            request_id: Uuid::new_v4(),
            job_id: job_id.clone(),
        })
        .unwrap_err();
    assert!(
        error.to_string().contains("UPDATE_STATE_INVALID"),
        "{error}"
    );
}
