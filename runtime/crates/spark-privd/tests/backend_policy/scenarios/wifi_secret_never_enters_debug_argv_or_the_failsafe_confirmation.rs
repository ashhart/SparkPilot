#[test]
fn wifi_secret_never_enters_debug_argv_or_the_failsafe_confirmation() {
    let root = tempfile::tempdir().unwrap();
    let journal_directory = root.path().join("network-rollbacks");
    let runner = Arc::new(RecordingRunner::new());
    let previous_wifi = Uuid::new_v4();
    runner.ok(Some(0), &format!("{previous_wifi}:802-11-wireless\n"), "");
    runner.ok(Some(1), "", "unknown connection");
    runner.ok(Some(0), "activated\n", "");
    let configuration_id = Uuid::new_v4();
    let secret = "correct-horse-42";
    let operation = PrivilegedOperation::ConnectWifi {
        request_id: configuration_id,
        ssid: "Main WiFi".into(),
        passphrase: Some(SecretString::new(secret)),
        hidden: false,
    };
    let debug = format!("{operation:?}");
    assert!(debug.contains("<redacted>"));
    assert!(!debug.contains(secret));

    let backend = DockerBackend::new("docker", false)
        .with_network_rollback_timeout(Duration::from_secs(60))
        .with_appliance_command_runner(runner.clone())
        .with_network_rollback_journal_dir(&journal_directory);
    assert_eq!(backend.execute(&operation).unwrap().code, "wifi_connected");
    assert!(
        journal_directory
            .join(NETWORK_ROLLBACK_JOURNAL_FILE)
            .is_file()
    );
    assert_eq!(
        backend
            .execute(&PrivilegedOperation::ConfirmNetworkChange {
                request_id: Uuid::new_v4(),
                configuration_id,
            })
            .unwrap()
            .code,
        "network_change_confirmed"
    );
    assert!(
        !journal_directory
            .join(NETWORK_ROLLBACK_JOURNAL_FILE)
            .exists()
    );
    let calls = runner.calls();
    assert!(
        calls
            .iter()
            .all(|(_, args)| args.iter().all(|arg| arg != secret))
    );
    assert!(calls.iter().any(|(program, args)| {
        program == NMCLI_BIN && args.windows(2).any(|pair| pair == ["connect", "Main WiFi"])
    }));
}
