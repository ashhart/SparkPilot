#[test]
fn direct_ethernet_never_selects_protected_fabric_loopback_bridge_or_overlay_interfaces() {
    let root = tempfile::tempdir().unwrap();
    let sysfs = root.path().join("sys-class-net");
    fs::create_dir_all(sysfs.join("enp1s0np0/device")).unwrap();
    fs::create_dir_all(sysfs.join("enp2s0/device")).unwrap();
    fs::write(sysfs.join("enp1s0np0/device/vendor"), "0x15b3\n").unwrap();
    fs::write(sysfs.join("enp2s0/device/vendor"), "0x10ec\n").unwrap();

    let runner = Arc::new(RecordingRunner::new());
    runner.ok(Some(1), "", "unknown connection");
    runner.ok(Some(0), "", "");
    runner.ok(
        Some(0),
        concat!(
            "enp1s0np0:ethernet:disconnected\n",
            "lo:ethernet:disconnected\n",
            "br-spark:ethernet:disconnected\n",
            "tailscale0:ethernet:disconnected\n",
            "eno1:ethernet:connected\n",
            "enp2s0:ethernet:disconnected\n"
        ),
        "",
    );
    runner.ok(Some(0), "created\n", "");
    runner.ok(Some(0), "activated\n", "");
    let backend = DockerBackend::new("docker", false)
        .with_appliance_command_runner(runner.clone())
        .with_network_sysfs_root(&sysfs)
        .with_network_rollback_journal_dir(root.path().join("network-rollbacks"));

    let configuration_id = Uuid::new_v4();
    backend
        .execute(&PrivilegedOperation::ConfigureDirectEthernet {
            request_id: configuration_id,
            enabled: true,
        })
        .unwrap();

    runner.ok(Some(0), "removed\n", "");
    let rollback = backend
        .execute(&PrivilegedOperation::RollbackNetworkChange {
            request_id: Uuid::new_v4(),
            configuration_id,
        })
        .unwrap();
    assert_eq!(rollback.code, "network_change_rolled_back");
    let calls = runner.argv_of(NMCLI_BIN);
    assert!(calls.iter().flatten().any(|argument| argument == "enp2s0"));
    assert_eq!(
        calls.last().unwrap(),
        &["connection", "delete", "id", "SparkPilot-Direct"]
    );
    for protected in ["enp1s0np0", "lo", "br-spark", "tailscale0", "eno1"] {
        assert!(
            calls.iter().flatten().all(|argument| argument != protected),
            "the general network helper mutated protected interface {protected}: {calls:?}"
        );
    }
}
