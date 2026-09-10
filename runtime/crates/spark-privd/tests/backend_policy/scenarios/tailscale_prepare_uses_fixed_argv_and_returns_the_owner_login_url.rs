#[test]
fn tailscale_prepare_uses_fixed_argv_and_returns_the_owner_login_url() {
    let (paths, _guard) = tailscale_test_paths(true, true);
    let runner = Arc::new(RecordingRunner::new());
    // The unit is not running yet, so a rollback would be allowed to stop it again.
    runner.ok(Some(3), "inactive\n", "");
    runner.ok(Some(0), "", "");
    runner.ok(Some(0), TAILSCALE_NEEDS_LOGIN_STATUS, "");
    runner.ok(
        Some(1),
        "{\"AuthURL\":\"https://login.tailscale.com/a/0123456789abcdef\",\"BackendState\":\"NeedsLogin\"}\n",
        "timeout waiting for Tailscale service to enter a Running state",
    );
    let backend = DockerBackend::new("docker", false)
        .with_appliance_command_runner(runner.clone())
        .with_tailscale_paths(paths);

    let response = backend
        .execute(&PrivilegedOperation::PrepareTailscale {
            request_id: Uuid::new_v4(),
        })
        .unwrap();

    assert_eq!(response.code, "tailscale_login_required");
    assert_eq!(response.details["provider"], "tailscale");
    assert_eq!(response.details["state"], "login_required");
    assert_eq!(
        response.details["authorization_url"],
        "https://login.tailscale.com/a/0123456789abcdef"
    );
    assert_eq!(response.details["created_service"], true);
    assert_eq!(response.details["attempted_login"], true);
    assert_eq!(
        runner.calls(),
        vec![
            (
                SYSTEMCTL_BIN.into(),
                vec!["is-active".into(), TAILSCALED_UNIT.into()],
            ),
            (
                SYSTEMCTL_BIN.into(),
                vec!["enable".into(), "--now".into(), TAILSCALED_UNIT.into()],
            ),
            (
                TAILSCALE_BIN.into(),
                vec!["status".into(), "--json".into()],
            ),
            (
                TAILSCALE_BIN.into(),
                vec![
                    "up".into(),
                    "--accept-dns=false".into(),
                    "--accept-routes=false".into(),
                    "--timeout=15s".into(),
                    "--json".into(),
                ],
            ),
        ]
    );
}
