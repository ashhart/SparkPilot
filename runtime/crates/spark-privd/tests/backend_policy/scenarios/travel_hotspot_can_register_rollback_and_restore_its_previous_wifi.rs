#[test]
fn travel_hotspot_can_register_rollback_and_restore_its_previous_wifi() {
    let root = tempfile::tempdir().unwrap();
    let runner = Arc::new(RecordingRunner::new());
    let previous_wifi = Uuid::new_v4();
    runner.ok(Some(0), &format!("{previous_wifi}:802-11-wireless\n"), "");
    runner.ok(Some(0), "wlan0:wifi:connected\n", "");
    runner.ok(Some(0), "", "");
    runner.ok(Some(0), "created\n", "");
    runner.ok(Some(0), "activated\n", "");
    let backend = DockerBackend::new("docker", false)
        .with_appliance_command_runner(runner.clone())
        .with_network_rollback_journal_dir(root.path().join("network-rollbacks"));
    let configuration_id = Uuid::new_v4();

    backend
        .execute(&PrivilegedOperation::ConfigureTravelAccessPoint {
            request_id: configuration_id,
            configuration_id,
            enabled: true,
            ssid: Some("Spark-Travel-Test".into()),
            passphrase: Some(SecretString::new("test-hotspot-password")),
        })
        .unwrap();
    runner.ok(Some(0), "removed\n", "");
    runner.ok(Some(0), "restored\n", "");
    let rollback = backend
        .execute(&PrivilegedOperation::RollbackNetworkChange {
            request_id: Uuid::new_v4(),
            configuration_id,
        })
        .unwrap();

    assert_eq!(rollback.code, "network_change_rolled_back");
    let calls = runner.argv_of(NMCLI_BIN);
    assert_eq!(calls.len(), 7);
    assert_eq!(
        calls[5],
        ["connection", "delete", "id", "SparkPilot-Travel"]
    );
    assert_eq!(
        calls[6],
        ["connection", "up", "uuid", &previous_wifi.to_string()]
    );
}
