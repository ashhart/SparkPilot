#[test]
fn concurrent_lan_changes_cannot_both_reach_network_manager() {
    let root = tempfile::tempdir().unwrap();
    let sysfs = root.path().join("sys-class-net");
    fs::create_dir_all(sysfs.join("eno1/device")).unwrap();
    fs::write(sysfs.join("eno1/device/vendor"), "0x10ec\n").unwrap();
    let runner = Arc::new(BlockingLanRunner::new(Uuid::new_v4(), true, false));
    let backend = Arc::new(
        DockerBackend::new("docker", false)
            .with_network_rollback_timeout(Duration::from_secs(60))
            .with_appliance_command_runner(runner.clone())
            .with_network_sysfs_root(&sysfs)
            .with_network_rollback_journal_dir(root.path().join("network-rollbacks")),
    );
    let first_configuration_id = Uuid::new_v4();
    let first_backend = backend.clone();
    let first = std::thread::spawn(move || {
        first_backend.execute(&manual_lan_operation(first_configuration_id))
    });
    runner.wait_for_activation();
    let calls_while_first_is_active = runner.calls();
    let second_backend = backend.clone();
    let second =
        std::thread::spawn(move || second_backend.execute(&manual_lan_operation(Uuid::new_v4())));

    std::thread::sleep(Duration::from_millis(50));
    assert_eq!(
        runner.calls(),
        calls_while_first_is_active,
        "the concurrent change reached NetworkManager while another mutation was active"
    );
    runner.release_activation();
    assert_eq!(
        first.join().unwrap().unwrap().code,
        "lan_ipv4_pending_confirmation"
    );
    let error = second
        .join()
        .unwrap()
        .expect_err("the concurrent request should see the pending first change");
    assert!(error.to_string().contains("pending network change"));
    assert_eq!(runner.calls(), calls_while_first_is_active);
    assert_eq!(
        backend
            .execute(&PrivilegedOperation::ConfirmNetworkChange {
                request_id: Uuid::new_v4(),
                configuration_id: first_configuration_id,
            })
            .unwrap()
            .code,
        "network_change_confirmed"
    );
}
