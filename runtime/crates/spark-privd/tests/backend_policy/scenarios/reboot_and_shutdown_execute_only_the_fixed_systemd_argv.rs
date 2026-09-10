#[test]
fn reboot_and_shutdown_execute_only_the_fixed_systemd_argv() {
    let runner = Arc::new(RecordingRunner::new());
    runner.ok(Some(0), "", "");
    runner.ok(Some(0), "", "");
    let backend = DockerBackend::new("docker", false).with_power_command_runner(runner.clone());

    let reboot = backend
        .execute(&PrivilegedOperation::Reboot {
            request_id: Uuid::new_v4(),
        })
        .unwrap();
    let shutdown = backend
        .execute(&PrivilegedOperation::Shutdown {
            request_id: Uuid::new_v4(),
        })
        .unwrap();

    assert_eq!(reboot.code, "reboot_scheduled");
    assert_eq!(shutdown.code, "shutdown_scheduled");
    assert_eq!(
        runner.calls(),
        vec![
            (
                SYSTEMCTL_BIN.into(),
                vec!["reboot".into(), "--no-block".into()],
            ),
            (
                SYSTEMCTL_BIN.into(),
                vec!["poweroff".into(), "--no-block".into()],
            ),
        ]
    );
}
