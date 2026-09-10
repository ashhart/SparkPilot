#[test]
fn direct_ethernet_refuses_unknown_unavailable_and_transitional_port_states() {
    for state in [
        "unknown",
        "unavailable",
        "unmanaged",
        "connecting",
        "connecting (getting IP configuration)",
        "disconnecting",
        "failed",
        "",
    ] {
        let root = tempfile::tempdir().unwrap();
        let runner = Arc::new(RecordingRunner::new());
        runner.ok(Some(1), "", "unknown connection");
        runner.ok(Some(0), "", "");
        runner.ok(Some(0), &format!("eno1:ethernet:{state}\n"), "");
        let backend = DockerBackend::new("docker", false)
            .with_appliance_command_runner(runner.clone())
            .with_network_sysfs_root(root.path().join("sys-class-net"))
            .with_network_rollback_journal_dir(root.path().join("network-rollbacks"));

        let error = backend
            .execute(&PrivilegedOperation::ConfigureDirectEthernet {
                request_id: Uuid::new_v4(),
                enabled: true,
            })
            .expect_err("an uncertain Ethernet state does not prove an unused port");

        assert!(error.to_string().contains("disconnected Ethernet port"));
        assert_eq!(
            runner.calls().len(),
            3,
            "state {state:?} allowed a mutation"
        );
    }
}
