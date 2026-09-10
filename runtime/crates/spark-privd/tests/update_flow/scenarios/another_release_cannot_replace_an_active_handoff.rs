#[test]
fn another_release_cannot_replace_an_active_handoff() {
    let h = Harness::new();
    h.stage("lab-0.1.0", b"deb-a");
    h.stage("lab-0.2.0", b"deb-b");
    h.runner.ok(Some(0), "", "");
    h.director().schedule("lab-0.1.0").unwrap();

    assert_refused(
        h.director().schedule("lab-0.2.0"),
        "UPDATE_ALREADY_SCHEDULED",
    );
    assert_eq!(
        fs::read_to_string(h.state.join("scheduled-release-id"))
            .unwrap()
            .trim(),
        "lab-0.1.0"
    );
    assert_eq!(h.runner.argv_of("/usr/bin/systemctl").len(), 1);
}
