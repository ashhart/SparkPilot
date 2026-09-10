#[test]
fn scheduling_failure_removes_the_new_handoff_marker() {
    let h = Harness::new();
    h.stage("lab-0.1.0", b"deb-bytes");
    h.runner
        .ok(Some(1), "", "systemd could not queue the worker");

    assert_refused(h.director().schedule("lab-0.1.0"), "UPDATE_SCHEDULE_FAILED");
    assert!(!h.state.join("scheduled-release-id").exists());
    assert!(h.runner.argv_of("/usr/bin/dpkg").is_empty());
}
