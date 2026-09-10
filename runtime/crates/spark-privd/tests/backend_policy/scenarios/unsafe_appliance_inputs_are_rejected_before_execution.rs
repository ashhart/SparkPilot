#[test]
fn unsafe_appliance_inputs_are_rejected_before_execution() {
    let runner = Arc::new(RecordingRunner::new());
    let backend = DockerBackend::new("docker", false).with_appliance_command_runner(runner.clone());
    let operations = [
        PrivilegedOperation::ConnectWifi {
            request_id: Uuid::new_v4(),
            ssid: "bad\nssid".into(),
            passphrase: None,
            hidden: false,
        },
        PrivilegedOperation::ConfigureBluetooth {
            request_id: Uuid::new_v4(),
            action: BluetoothAction::Pair,
            device_address: Some("not-an-address".into()),
        },
        PrivilegedOperation::ConfigureSystemTime {
            request_id: Uuid::new_v4(),
            timezone: "../../etc/passwd".into(),
            ntp_enabled: true,
        },
    ];
    for operation in operations {
        assert!(matches!(
            backend.execute(&operation),
            Err(BackendError::InvalidInput(_))
        ));
    }
    assert!(runner.calls().is_empty());
}
