#[test]
fn confirming_while_rollback_executes_reports_the_race_as_a_rejection() {
    let root = tempfile::tempdir().unwrap();
    let sysfs = root.path().join("sys-class-net");
    fs::create_dir_all(sysfs.join("eno1/device")).unwrap();
    fs::write(sysfs.join("eno1/device/vendor"), "0x10ec\n").unwrap();
    let runner = Arc::new(BlockingLanRunner::new(Uuid::new_v4(), false, true));
    let backend = Arc::new(
        DockerBackend::new("docker", false)
            .with_network_rollback_timeout(Duration::from_secs(60))
            .with_appliance_command_runner(runner.clone())
            .with_network_sysfs_root(&sysfs)
            .with_network_rollback_journal_dir(root.path().join("network-rollbacks")),
    );
    let configuration_id = Uuid::new_v4();
    backend
        .execute(&manual_lan_operation(configuration_id))
        .unwrap();
    let worker_backend = backend.clone();
    let rollback = std::thread::spawn(move || {
        worker_backend.execute(&PrivilegedOperation::RollbackNetworkChange {
            request_id: Uuid::new_v4(),
            configuration_id,
        })
    });

    runner.wait_for_restore();
    let confirmation = backend
        .execute(&PrivilegedOperation::ConfirmNetworkChange {
            request_id: Uuid::new_v4(),
            configuration_id,
        })
        .unwrap();
    assert!(!confirmation.accepted);
    assert_eq!(confirmation.code, "NETWORK_ROLLBACK_IN_PROGRESS");
    assert_eq!(confirmation.details["resolved"], false);
    let second_rollback = backend
        .execute(&PrivilegedOperation::RollbackNetworkChange {
            request_id: Uuid::new_v4(),
            configuration_id,
        })
        .unwrap();
    assert!(!second_rollback.accepted);
    assert_eq!(second_rollback.code, "NETWORK_ROLLBACK_IN_PROGRESS");
    assert_eq!(second_rollback.details["resolved"], false);
    runner.release_restore();
    assert_eq!(
        rollback.join().unwrap().unwrap().code,
        "network_change_rolled_back"
    );
}
