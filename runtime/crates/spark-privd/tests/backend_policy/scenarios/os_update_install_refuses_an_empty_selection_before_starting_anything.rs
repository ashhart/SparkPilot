#[test]
fn os_update_install_refuses_an_empty_selection_before_starting_anything() {
    let runner = Arc::new(RecordingRunner::new());
    let backend = DockerBackend::new("docker", false).with_appliance_command_runner(runner.clone());
    let error = backend
        .execute(&PrivilegedOperation::InstallSystemUpdates {
            request_id: Uuid::new_v4(),
            system_packages: false,
            firmware: false,
        })
        .unwrap_err();
    assert!(matches!(error, BackendError::InvalidInput(_)));
    assert!(runner.calls().is_empty());
}
