#[test]
fn tailscale_prepare_installs_the_vendor_package_when_missing() {
    let (paths, _guard) = tailscale_test_paths(false, false);
    let runner = Arc::new(RecordingRunner::new());
    for _ in 0..6 {
        runner.ok(Some(0), "", "");
    }
    runner.ok(Some(0), TAILSCALE_RUNNING_STATUS, "");
    let backend = DockerBackend::new("docker", false)
        .with_appliance_command_runner(runner.clone())
        .with_tailscale_paths(paths);

    let response = backend
        .execute(&PrivilegedOperation::PrepareTailscale {
            request_id: Uuid::new_v4(),
        })
        .unwrap();

    assert_eq!(response.code, "tailscale_ready");
    assert_eq!(response.details["state"], "ready");
    let calls = runner.calls();
    let systemd_run: Vec<Vec<String>> = calls
        .iter()
        .filter(|(program, _)| program == SYSTEMD_RUN_BIN)
        .map(|(_, args)| args.clone())
        .collect();
    assert_eq!(systemd_run.len(), 4, "keyring, apt source, update, install: {calls:?}");
    let host_commands: Vec<Vec<&str>> = systemd_run
        .iter()
        .map(|args| {
            let start = args.iter().position(|arg| arg == "--").unwrap() + 1;
            args[start..].iter().map(String::as_str).collect()
        })
        .collect();
    assert_eq!(
        host_commands,
        vec![
            vec![
                CURL_BIN,
                "--proto",
                "=https",
                "--tlsv1.2",
                "--fail",
                "--silent",
                "--show-error",
                "--location",
                "--output",
                TAILSCALE_KEYRING_PATH,
                TAILSCALE_KEYRING_URL,
            ],
            vec![
                CURL_BIN,
                "--proto",
                "=https",
                "--tlsv1.2",
                "--fail",
                "--silent",
                "--show-error",
                "--location",
                "--output",
                TAILSCALE_APT_SOURCE_PATH,
                TAILSCALE_APT_SOURCE_URL,
            ],
            vec![APT_GET_BIN, "update"],
            vec![
                APT_GET_BIN,
                "install",
                "-y",
                "--no-install-recommends",
                "tailscale",
            ],
        ]
    );
    assert_eq!(
        calls[4],
        (
            SYSTEMCTL_BIN.into(),
            vec!["is-active".into(), TAILSCALED_UNIT.into()],
        ),
        "the unit is read before it is touched, so a rollback knows what this prepare started"
    );
    assert_eq!(
        calls[5],
        (
            SYSTEMCTL_BIN.into(),
            vec!["enable".into(), "--now".into(), TAILSCALED_UNIT.into()],
        )
    );
}
