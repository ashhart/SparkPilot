#[test]
fn tailscale_status_reports_ready_with_the_magicdns_name_and_address() {
    let (paths, _guard) = tailscale_test_paths(true, true);
    let runner = Arc::new(RecordingRunner::new());
    runner.ok(Some(0), TAILSCALE_RUNNING_STATUS, "");
    let backend = DockerBackend::new("docker", false)
        .with_appliance_command_runner(runner.clone())
        .with_tailscale_paths(paths);

    let response = backend
        .execute(&PrivilegedOperation::TailscaleStatus {
            request_id: Uuid::new_v4(),
        })
        .unwrap();

    assert_eq!(response.code, "tailscale_status");
    assert_eq!(response.details["state"], "ready");
    assert_eq!(response.details["hostname"], "spark-example.tail1234.ts.net");
    assert_eq!(response.details["address"], "100.96.4.2");
    assert_eq!(response.details["tailnet"], "tail1234.ts.net");
    assert!(response.details["authorization_url"].is_null());
    assert_eq!(
        runner.calls(),
        vec![(
            TAILSCALE_BIN.into(),
            vec!["status".into(), "--json".into()]
        )]
    );
}
