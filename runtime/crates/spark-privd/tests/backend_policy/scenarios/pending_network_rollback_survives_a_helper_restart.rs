#[test]
fn pending_network_rollback_survives_a_helper_restart() {
    let root = tempfile::tempdir().unwrap();
    let journal_directory = root.path().join("network-rollbacks");
    let first_runner = Arc::new(RecordingRunner::new());
    let previous_wifi = Uuid::new_v4();
    first_runner.ok(Some(0), &format!("{previous_wifi}:802-11-wireless\n"), "");
    first_runner.ok(Some(1), "", "unknown connection");
    first_runner.ok(Some(0), "activated\n", "");
    let configuration_id = Uuid::new_v4();
    let first_backend = DockerBackend::new("docker", false)
        .with_network_rollback_timeout(Duration::from_secs(60))
        .with_appliance_command_runner(first_runner)
        .with_network_rollback_journal_dir(&journal_directory);
    let secret = "correct-horse-42";
    first_backend
        .execute(&PrivilegedOperation::ConnectWifi {
            request_id: configuration_id,
            ssid: "Main WiFi".into(),
            passphrase: Some(SecretString::new(secret)),
            hidden: false,
        })
        .unwrap();

    let journal_path = journal_directory.join(NETWORK_ROLLBACK_JOURNAL_FILE);
    let journal = fs::read_to_string(&journal_path).unwrap();
    assert!(!journal.contains(secret));
    assert!(!journal.to_ascii_lowercase().contains("passphrase"));
    let journal_metadata = fs::symlink_metadata(&journal_path).unwrap();
    assert!(journal_metadata.is_file());
    assert!(!journal_metadata.file_type().is_symlink());
    assert_eq!(journal_metadata.mode() & 0o777, 0o600);
    assert_eq!(journal_metadata.uid(), unsafe { libc::geteuid() });
    assert_eq!(
        fs::symlink_metadata(&journal_directory).unwrap().mode() & 0o777,
        0o700
    );
    assert_eq!(fs::read_dir(&journal_directory).unwrap().count(), 1);

    let restarted_runner = Arc::new(RecordingRunner::new());
    restarted_runner.ok(Some(0), "", "");
    restarted_runner.ok(Some(0), "", "");
    let restarted_backend = DockerBackend::new("docker", false)
        .with_network_rollback_timeout(Duration::from_secs(60))
        .with_appliance_command_runner(restarted_runner.clone())
        .with_network_rollback_journal_dir(&journal_directory);
    let response = restarted_backend
        .execute(&PrivilegedOperation::RollbackNetworkChange {
            request_id: Uuid::new_v4(),
            configuration_id,
        })
        .unwrap();

    assert_eq!(response.code, "network_change_rolled_back");
    assert_eq!(restarted_runner.calls().len(), 2);
    assert!(!journal_path.exists());
}
