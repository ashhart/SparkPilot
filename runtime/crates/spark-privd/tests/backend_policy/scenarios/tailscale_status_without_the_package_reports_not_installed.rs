#[test]
fn tailscale_status_without_the_package_reports_not_installed() {
    let (paths, _guard) = tailscale_test_paths(false, true);
    let runner = Arc::new(RecordingRunner::new());
    let backend = DockerBackend::new("docker", false)
        .with_appliance_command_runner(runner.clone())
        .with_tailscale_paths(paths);

    let response = backend
        .execute(&PrivilegedOperation::TailscaleStatus {
            request_id: Uuid::new_v4(),
        })
        .unwrap();

    assert_eq!(response.details["state"], "not_installed");
    assert_eq!(response.details["installable"], true);
    assert!(runner.calls().is_empty());
}
