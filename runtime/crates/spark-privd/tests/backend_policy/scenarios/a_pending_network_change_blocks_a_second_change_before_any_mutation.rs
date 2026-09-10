#[test]
fn a_pending_network_change_blocks_a_second_change_before_any_mutation() {
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
    runner.ok(Some(0), "", "");
    runner.ok(Some(0), "modified\n", "");
    runner.ok(Some(0), "activated\n", "");
    let backend = DockerBackend::new("docker", false)
        .with_appliance_command_runner(runner.clone())
        .with_network_sysfs_root(&sysfs)
        .with_network_rollback_journal_dir(root.path().join("network-rollbacks"));

    backend
        .execute(&manual_lan_operation(Uuid::new_v4()))
        .expect("the first change should wait for confirmation");
    let calls_before_second = runner.calls();
    let error = backend
        .execute(&manual_lan_operation(Uuid::new_v4()))
        .expect_err("a second pending network change must fail closed");

    assert!(
        error.to_string().contains("pending network change"),
        "{error}"
    );
    assert_eq!(
        runner.calls(),
        calls_before_second,
        "the second request reached NetworkManager before it was rejected"
    );
}
