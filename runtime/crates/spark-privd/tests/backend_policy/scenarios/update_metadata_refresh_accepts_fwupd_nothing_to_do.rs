#[test]
fn update_metadata_refresh_accepts_fwupd_nothing_to_do() {
    let runner = Arc::new(RecordingRunner::new());
    runner.ok(Some(0), "", "");
    runner.ok(Some(2), "", "");
    let backend = DockerBackend::new("docker", false).with_appliance_command_runner(runner.clone());

    let response = backend
        .execute(&PrivilegedOperation::RefreshSystemUpdates {
            request_id: Uuid::new_v4(),
        })
        .unwrap();

    assert_eq!(response.code, "software_updates_refreshed");
    // Run refreshes outside the helper sandbox with fixed program and argument choices.
    let calls = runner.calls();
    assert_eq!(calls.len(), 2);
    for (program, _) in &calls {
        assert_eq!(program, SYSTEMD_RUN_BIN);
    }
    let apt = &calls[0].1;
    let separator = apt
        .iter()
        .position(|arg| arg == "--")
        .expect("argv separator");
    assert_eq!(
        &apt[separator + 1..],
        &[APT_GET_BIN.to_owned(), "update".to_owned()]
    );
    assert!(apt.contains(&"--wait".to_owned()));
    assert!(apt.contains(&"--pipe".to_owned()));
    assert!(apt.iter().all(|arg| !arg.contains("sh -c")));
    let fwupd = &calls[1].1;
    let separator = fwupd
        .iter()
        .position(|arg| arg == "--")
        .expect("argv separator");
    assert_eq!(
        &fwupd[separator + 1..],
        &[
            FWUPDMGR_BIN.to_owned(),
            "refresh".to_owned(),
            "--force".to_owned()
        ]
    );
}
