#[test]
fn unsafe_journal_permissions_fail_closed() {
    let root = tempfile::tempdir().unwrap();
    let journal_directory = root.path().join("network-rollbacks");
    fs::create_dir(&journal_directory).unwrap();
    fs::set_permissions(&journal_directory, fs::Permissions::from_mode(0o777)).unwrap();

    let runner = Arc::new(RecordingRunner::new());
    let previous_wifi = Uuid::new_v4();
    runner.ok(Some(0), &format!("{previous_wifi}:802-11-wireless\n"), "");
    runner.ok(Some(1), "", "unknown connection");
    runner.ok(Some(0), "activated\n", "");
    let backend = DockerBackend::new("docker", false)
        .with_appliance_command_runner(runner.clone())
        .with_network_rollback_journal_dir(&journal_directory);
    let error = backend
        .execute(&PrivilegedOperation::ConnectWifi {
            request_id: Uuid::new_v4(),
            ssid: "Main WiFi".into(),
            passphrase: None,
            hidden: false,
        })
        .expect_err("an unsafe journal directory must fail closed");

    assert!(error.to_string().contains("journal"));
    assert!(
        !journal_directory
            .join(NETWORK_ROLLBACK_JOURNAL_FILE)
            .exists()
    );
    assert!(
        runner.calls().is_empty(),
        "unsafe journal permissions were detected only after mutation"
    );
}
