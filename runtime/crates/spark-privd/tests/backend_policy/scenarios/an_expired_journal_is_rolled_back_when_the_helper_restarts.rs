#[test]
fn an_expired_journal_is_rolled_back_when_the_helper_restarts() {
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
    first_backend
        .execute(&PrivilegedOperation::ConnectWifi {
            request_id: configuration_id,
            ssid: "Main WiFi".into(),
            passphrase: None,
            hidden: false,
        })
        .unwrap();
    let journal_path = journal_directory.join(NETWORK_ROLLBACK_JOURNAL_FILE);
    let mut journal: serde_json::Value =
        serde_json::from_slice(&fs::read(&journal_path).unwrap()).unwrap();
    journal["pending"][configuration_id.to_string()]["expires_at_unix_millis"] = 0.into();
    fs::write(&journal_path, serde_json::to_vec(&journal).unwrap()).unwrap();

    let restarted_runner = Arc::new(RecordingRunner::new());
    restarted_runner.ok(Some(0), "removed\n", "");
    restarted_runner.ok(Some(0), "restored\n", "");
    let _restarted_backend = DockerBackend::new("docker", false)
        .with_appliance_command_runner(restarted_runner.clone())
        .with_network_rollback_journal_dir(&journal_directory);
    for _ in 0..100 {
        if !journal_path.exists() && restarted_runner.calls().len() == 2 {
            break;
        }
        std::thread::sleep(Duration::from_millis(10));
    }

    assert!(!journal_path.exists());
    assert_eq!(restarted_runner.calls().len(), 2);
}
