#[test]
fn manual_lan_ipv4_rejects_a_duplicate_before_profile_mutation() {
    let root = tempfile::tempdir().unwrap();
    let sysfs = root.path().join("sys-class-net");
    fs::create_dir_all(sysfs.join("eno1/device")).unwrap();
    fs::write(sysfs.join("eno1/device/vendor"), "0x10ec\n").unwrap();
    let connection_uuid = Uuid::new_v4();
    let runner = Arc::new(RecordingRunner::new());
    runner.ok(Some(0), &format!("{connection_uuid}:ethernet:eno1\n"), "");
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
    runner.ok(Some(1), "", "duplicate response");
    let backend = DockerBackend::new("docker", false)
        .with_appliance_command_runner(runner.clone())
        .with_network_sysfs_root(&sysfs)
        .with_network_rollback_journal_dir(root.path().join("network-rollbacks"));

    let response = backend
        .execute(&PrivilegedOperation::ConfigureLanIpv4 {
            request_id: Uuid::new_v4(),
            configuration_id: Uuid::new_v4(),
            address: "192.168.100.63".parse().unwrap(),
            prefix_length: 24,
            gateway: "192.168.100.1".parse().unwrap(),
            dns_servers: vec!["1.1.1.1".parse().unwrap()],
        })
        .unwrap();

    assert!(!response.accepted);
    assert_eq!(response.code, "NETWORK_ADDRESS_IN_USE");
    assert_eq!(runner.calls().len(), 3);
    assert!(
        !root
            .path()
            .join("network-rollbacks")
            .join(NETWORK_ROLLBACK_JOURNAL_FILE)
            .exists()
    );
}
