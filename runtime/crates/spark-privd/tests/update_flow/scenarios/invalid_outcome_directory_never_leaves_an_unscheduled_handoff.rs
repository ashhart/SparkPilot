#[test]
fn invalid_outcome_directory_never_leaves_an_unscheduled_handoff() {
    let h = Harness::new();
    h.stage("lab-0.1.0", b"deb-bytes");
    fs::create_dir_all(&h.state).unwrap();
    let victim = h.dir.path().join("victim-outcomes");
    fs::create_dir(&victim).unwrap();
    std::os::unix::fs::symlink(&victim, h.state.join("outcomes")).unwrap();

    assert_refused(h.director().schedule("lab-0.1.0"), "UPDATE_STATE_INVALID");

    assert!(!h.state.join("scheduled-release-id").exists());
    assert!(h.runner.argv_of("/usr/bin/systemctl").is_empty());
    assert!(fs::read_dir(victim).unwrap().next().is_none());
}
