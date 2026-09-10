#[test]
fn the_lan_rollback_timer_starts_only_after_activation_finishes() {
    let root = tempfile::tempdir().unwrap();
    let sysfs = root.path().join("sys-class-net");
    fs::create_dir_all(sysfs.join("eno1/device")).unwrap();
    fs::write(sysfs.join("eno1/device/vendor"), "0x10ec\n").unwrap();
    let runner = Arc::new(BlockingLanRunner::new(Uuid::new_v4(), true, false));
    let backend = Arc::new(
        DockerBackend::new("docker", false)
            .with_network_rollback_timeout(Duration::from_millis(100))
            .with_appliance_command_runner(runner.clone())
            .with_network_sysfs_root(&sysfs)
            .with_network_rollback_journal_dir(root.path().join("network-rollbacks")),
    );
    let configuration_id = Uuid::new_v4();
    let worker_backend = backend.clone();
    let worker =
        std::thread::spawn(move || worker_backend.execute(&manual_lan_operation(configuration_id)));

    runner.wait_for_activation();
    std::thread::sleep(Duration::from_millis(250));
    assert!(
        !runner.restore_started(),
        "the failsafe restored the profile while NetworkManager was still activating it"
    );
    runner.release_activation();
    assert_eq!(
        worker.join().unwrap().unwrap().code,
        "lan_ipv4_pending_confirmation"
    );
    assert_eq!(
        backend
            .execute(&PrivilegedOperation::ConfirmNetworkChange {
                request_id: Uuid::new_v4(),
                configuration_id,
            })
            .unwrap()
            .code,
        "network_change_confirmed"
    );
}
