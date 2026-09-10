#[test]
fn an_expired_network_rollback_retries_until_the_profile_is_restored() {
    let root = tempfile::tempdir().unwrap();
    let journal_directory = root.path().join("network-rollbacks");
    let runner = Arc::new(RecordingRunner::new());
    let previous_wifi = Uuid::new_v4();
    runner.ok(Some(0), &format!("{previous_wifi}:802-11-wireless\n"), "");
    runner.ok(Some(1), "", "unknown connection");
    runner.ok(Some(0), "activated\n", "");
    runner.ok(Some(1), "", "temporary delete failure");
    runner.ok(Some(0), "restored\n", "");
    runner.ok(Some(0), "removed\n", "");
    runner.ok(Some(0), "restored\n", "");
    let backend = DockerBackend::new("docker", false)
        .with_network_rollback_timeout(Duration::from_millis(25))
        .with_appliance_command_runner(runner.clone())
        .with_network_rollback_journal_dir(&journal_directory);
    backend
        .execute(&PrivilegedOperation::ConnectWifi {
            request_id: Uuid::new_v4(),
            ssid: "Main WiFi".into(),
            passphrase: None,
            hidden: false,
        })
        .unwrap();
    let journal_path = journal_directory.join(NETWORK_ROLLBACK_JOURNAL_FILE);

    for _ in 0..200 {
        if !journal_path.exists() && runner.calls().len() == 7 {
            break;
        }
        std::thread::sleep(Duration::from_millis(10));
    }

    assert!(
        !journal_path.exists(),
        "a failed rollback was never retried"
    );
    assert_eq!(runner.calls().len(), 7);
}
