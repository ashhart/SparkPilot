#[test]
fn rollback_journal_never_follows_a_symlink() {
    let root = tempfile::tempdir().unwrap();
    let journal_directory = root.path().join("network-rollbacks");
    fs::create_dir(&journal_directory).unwrap();
    fs::set_permissions(&journal_directory, fs::Permissions::from_mode(0o700)).unwrap();
    let victim = root.path().join("victim");
    fs::write(&victim, b"keep this file").unwrap();
    std::os::unix::fs::symlink(
        &victim,
        journal_directory.join(NETWORK_ROLLBACK_JOURNAL_FILE),
    )
    .unwrap();

    let runner = Arc::new(RecordingRunner::new());
    let previous_wifi = Uuid::new_v4();
    runner.ok(Some(0), &format!("{previous_wifi}:802-11-wireless\n"), "");
    runner.ok(Some(1), "", "unknown connection");
    runner.ok(Some(0), "activated\n", "");
    let backend = DockerBackend::new("docker", false)
        .with_network_rollback_timeout(Duration::from_secs(60))
        .with_appliance_command_runner(runner.clone())
        .with_network_rollback_journal_dir(&journal_directory);
    let error = backend
        .execute(&PrivilegedOperation::ConnectWifi {
            request_id: Uuid::new_v4(),
            ssid: "Main WiFi".into(),
            passphrase: Some(SecretString::new("correct-horse-42")),
            hidden: false,
        })
        .expect_err("an unsafe journal must reject before the network change");

    assert!(error.to_string().contains("journal"));
    assert_eq!(fs::read(&victim).unwrap(), b"keep this file");
    assert!(
        runner.calls().is_empty(),
        "an unsafe journal was detected only after mutating NetworkManager"
    );
}
