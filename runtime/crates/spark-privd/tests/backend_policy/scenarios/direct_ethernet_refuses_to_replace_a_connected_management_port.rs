#[test]
fn direct_ethernet_refuses_to_replace_a_connected_management_port() {
    let root = tempfile::tempdir().unwrap();
    let runner = Arc::new(RecordingRunner::new());
    runner.ok(Some(1), "", "unknown connection");
    runner.ok(Some(0), "", "");
    runner.ok(Some(0), "eno1:ethernet:connected\n", "");
    runner.ok(Some(0), "created\n", "");
    runner.ok(Some(0), "activated\n", "");
    let backend = DockerBackend::new("docker", false)
        .with_appliance_command_runner(runner.clone())
        .with_network_sysfs_root(root.path().join("sys-class-net"))
        .with_network_rollback_journal_dir(root.path().join("network-rollbacks"));

    let error = backend
        .execute(&PrivilegedOperation::ConfigureDirectEthernet {
            request_id: Uuid::new_v4(),
            enabled: true,
        })
        .expect_err("direct Ethernet must not displace the connected management profile");

    assert!(error.to_string().contains("disconnected Ethernet port"));
    assert_eq!(runner.calls().len(), 3, "a mutation command was attempted");
}
