#[test]
fn detached_update_status_survives_director_restart() {
    let h = Harness::new();
    let staged = h.stage("lab-0.1.0", b"deb-bytes");
    h.runner.ok(Some(0), "", "");
    h.director().schedule("lab-0.1.0").unwrap();
    assert_eq!(
        h.director().update_status("lab-0.1.0").unwrap(),
        Some(RuntimeUpdateStatus::Scheduled {
            release_id: "lab-0.1.0".into()
        })
    );

    let report = h.verify_report(&staged);
    h.runner.ok(Some(0), "", "");
    h.runner.ok(Some(0), &report, "");
    h.runner.ok(Some(0), "", "");
    h.runner.ok(Some(0), "", "");
    h.director().apply_scheduled("lab-0.1.0").unwrap();

    let restarted = h.director();
    assert!(matches!(
        restarted.update_status("lab-0.1.0").unwrap(),
        Some(RuntimeUpdateStatus::Completed { .. })
    ));
}
