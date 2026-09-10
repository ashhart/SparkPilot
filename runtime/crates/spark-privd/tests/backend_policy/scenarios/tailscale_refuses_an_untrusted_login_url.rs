#[test]
fn tailscale_refuses_an_untrusted_login_url() {
    let (paths, _guard) = tailscale_test_paths(true, true);
    let runner = Arc::new(RecordingRunner::new());
    runner.ok(Some(0), "", "");
    runner.ok(Some(0), TAILSCALE_NEEDS_LOGIN_STATUS, "");
    runner.ok(
        Some(1),
        "{\"AuthURL\":\"https://login.tailscale.com.evil.example/a/0123\",\"BackendState\":\"NeedsLogin\"}\n",
        "",
    );
    let backend = DockerBackend::new("docker", false)
        .with_appliance_command_runner(runner.clone())
        .with_tailscale_paths(paths);

    let error = backend
        .execute(&PrivilegedOperation::PrepareTailscale {
            request_id: Uuid::new_v4(),
        })
        .expect_err("a login URL off login.tailscale.com must never reach the app");

    assert!(matches!(error, BackendError::Failure(_)), "{error}");
    assert!(error.to_string().contains("untrusted"), "{error}");
}
