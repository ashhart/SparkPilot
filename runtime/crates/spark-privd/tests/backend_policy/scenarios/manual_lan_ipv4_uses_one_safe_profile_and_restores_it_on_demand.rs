#[test]
fn manual_lan_ipv4_uses_one_safe_profile_and_restores_it_on_demand() {
    let root = tempfile::tempdir().unwrap();
    let sysfs = root.path().join("sys-class-net");
    fs::create_dir_all(sysfs.join("eno1/device")).unwrap();
    fs::create_dir_all(sysfs.join("enp1s0np0/device")).unwrap();
    fs::write(sysfs.join("eno1/device/vendor"), "0x10ec\n").unwrap();
    fs::write(sysfs.join("enp1s0np0/device/vendor"), "0x15b3\n").unwrap();
    let connection_uuid = Uuid::new_v4();
    let configuration_id = Uuid::new_v4();
    let runner = Arc::new(RecordingRunner::new());
    runner.ok(
        Some(0),
        &format!(
            "{}:802-3-ethernet:enp1s0np0\n{connection_uuid}:802-3-ethernet:eno1\n",
            Uuid::new_v4()
        ),
        "",
    );
    runner.ok(
        Some(0),
        concat!(
            "ipv4.method:auto\n",
            "ipv4.addresses:\n",
            "ipv4.gateway:\n",
            "ipv4.dns:\n",
            "ipv4.ignore-auto-dns:no\n"
        ),
        "",
    );
    runner.ok(Some(0), "", "");
    runner.ok(Some(0), "modified\n", "");
    runner.ok(Some(0), "activated\n", "");
    runner.ok(Some(0), "restored\n", "");
    runner.ok(Some(0), "activated\n", "");
    let backend = DockerBackend::new("docker", false)
        .with_appliance_command_runner(runner.clone())
        .with_network_sysfs_root(&sysfs)
        .with_network_rollback_journal_dir(root.path().join("network-rollbacks"));

    let response = backend
        .execute(&PrivilegedOperation::ConfigureLanIpv4 {
            request_id: configuration_id,
            configuration_id,
            address: "192.168.100.63".parse().unwrap(),
            prefix_length: 24,
            gateway: "192.168.100.1".parse().unwrap(),
            dns_servers: vec!["1.1.1.1".parse().unwrap(), "8.8.8.8".parse().unwrap()],
        })
        .unwrap();

    assert_eq!(response.code, "lan_ipv4_pending_confirmation");
    assert_eq!(response.details["auto_revert_seconds"], 30);
    assert!(
        root.path()
            .join("network-rollbacks")
            .join(NETWORK_ROLLBACK_JOURNAL_FILE)
            .is_file()
    );
    assert_eq!(
        backend
            .execute(&PrivilegedOperation::RollbackNetworkChange {
                request_id: Uuid::new_v4(),
                configuration_id,
            })
            .unwrap()
            .code,
        "network_change_rolled_back"
    );
    let calls = runner.calls();
    assert!(calls.iter().any(|(program, args)| {
        program == ARPING_BIN
            && args == &["-D", "-c", "2", "-w", "3", "-I", "eno1", "192.168.100.63"]
    }));
    assert!(calls.iter().any(|(program, args)| {
        program == NMCLI_BIN
            && args
                .windows(2)
                .any(|pair| pair == ["ipv4.addresses", "192.168.100.63/24"])
            && args
                .windows(2)
                .any(|pair| pair == ["ipv4.gateway", "192.168.100.1"])
            && args
                .windows(2)
                .any(|pair| pair == ["ipv4.dns", "1.1.1.1,8.8.8.8"])
    }));
    assert!(calls.iter().any(|(program, args)| {
        program == NMCLI_BIN
            && args.windows(2).any(|pair| pair == ["ipv4.method", "auto"])
            && args
                .windows(2)
                .any(|pair| pair == ["ipv4.ignore-auto-dns", "no"])
    }));
    assert!(
        calls
            .iter()
            .all(|(_, args)| args.iter().all(|argument| argument != "enp1s0np0"))
    );
}
