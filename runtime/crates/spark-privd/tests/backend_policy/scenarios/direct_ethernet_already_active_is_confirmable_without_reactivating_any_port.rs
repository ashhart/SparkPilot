#[test]
fn direct_ethernet_already_active_is_confirmable_without_reactivating_any_port() {
    let root = tempfile::tempdir().unwrap();
    let runner = Arc::new(RecordingRunner::new());
    let profile_uuid = Uuid::new_v4().to_string();
    runner.ok(Some(0), &profile_uuid, "");
    runner.ok(Some(0), &profile_uuid, "");
    let backend = DockerBackend::new("docker", false)
        .with_appliance_command_runner(runner.clone())
        .with_network_sysfs_root(root.path().join("sys-class-net"))
        .with_network_rollback_journal_dir(root.path().join("network-rollbacks"));
    let configuration_id = Uuid::new_v4();

    let enabled = backend
        .execute(&PrivilegedOperation::ConfigureDirectEthernet {
            request_id: configuration_id,
            enabled: true,
        })
        .unwrap();
    assert!(enabled.accepted);
    assert_eq!(
        runner.calls().len(),
        2,
        "an active direct port was reconfigured"
    );
    let confirmed = backend
        .execute(&PrivilegedOperation::ConfirmNetworkChange {
            request_id: Uuid::new_v4(),
            configuration_id,
        })
        .unwrap();
    assert_eq!(confirmed.code, "network_change_confirmed");
    assert_eq!(runner.calls().len(), 2);
}
