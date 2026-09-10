#[test]
fn direct_ethernet_fails_closed_when_only_protected_interfaces_exist() {
    let root = tempfile::tempdir().unwrap();
    let sysfs = root.path().join("sys-class-net");
    fs::create_dir_all(sysfs.join("enp1s0np0/device")).unwrap();
    fs::write(sysfs.join("enp1s0np0/device/vendor"), "0x15b3\n").unwrap();
    let runner = Arc::new(RecordingRunner::new());
    runner.ok(Some(1), "", "unknown connection");
    runner.ok(Some(0), "", "");
    runner.ok(
        Some(0),
        "enp1s0np0:ethernet:disconnected\nlo:ethernet:disconnected\nbr-spark:ethernet:disconnected\ntailscale0:ethernet:disconnected\n",
        "",
    );
    let backend = DockerBackend::new("docker", false)
        .with_appliance_command_runner(runner.clone())
        .with_network_sysfs_root(&sysfs)
        .with_network_rollback_journal_dir(root.path().join("network-rollbacks"));

    let error = backend
        .execute(&PrivilegedOperation::ConfigureDirectEthernet {
            request_id: Uuid::new_v4(),
            enabled: true,
        })
        .expect_err("protected interfaces must never be a direct-LAN fallback");

    assert!(error.to_string().contains("disconnected Ethernet port"));
    assert_eq!(runner.calls().len(), 3, "a mutation command was attempted");
}
