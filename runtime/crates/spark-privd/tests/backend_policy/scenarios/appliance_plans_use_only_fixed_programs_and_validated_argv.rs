#[test]
fn appliance_plans_use_only_fixed_programs_and_validated_argv() {
    let runner = Arc::new(RecordingRunner::new());
    let backend = DockerBackend::new("docker", true).with_appliance_command_runner(runner.clone());
    let cases = [
        (
            PrivilegedOperation::ConfigureBluetooth {
                request_id: Uuid::new_v4(),
                action: BluetoothAction::Pair,
                device_address: Some("02:00:00:00:00:42".into()),
            },
            BLUETOOTHCTL_BIN,
            serde_json::json!(["pair", "02:00:00:00:00:42"]),
        ),
        (
            PrivilegedOperation::SetPowerProfile {
                request_id: Uuid::new_v4(),
                mode_id: 2,
            },
            NVPMODEL_BIN,
            serde_json::json!(["-m", "2"]),
        ),
        (
            PrivilegedOperation::ConfigureSystemTime {
                request_id: Uuid::new_v4(),
                timezone: "Europe/London".into(),
                ntp_enabled: true,
            },
            TIMEDATECTL_BIN,
            serde_json::json!(["set-timezone", "Europe/London"]),
        ),
    ];
    for (operation, program, args) in cases {
        let response = backend.execute(&operation).unwrap();
        assert_eq!(response.details["program"], program);
        assert_eq!(response.details["args"], args);
    }
    let update = backend
        .execute(&PrivilegedOperation::InstallSystemUpdates {
            request_id: Uuid::new_v4(),
            system_packages: true,
            firmware: false,
        })
        .unwrap();
    assert_eq!(update.details["commands"][0][0], APT_GET_BIN);
    let refresh = backend
        .execute(&PrivilegedOperation::RefreshSystemUpdates {
            request_id: Uuid::new_v4(),
        })
        .unwrap();
    assert_eq!(
        refresh.details["commands"][0],
        serde_json::json!([APT_GET_BIN, "update"])
    );
    assert_eq!(
        refresh.details["commands"][1],
        serde_json::json!([FWUPDMGR_BIN, "refresh --force"])
    );
    assert!(runner.calls().is_empty());
}
