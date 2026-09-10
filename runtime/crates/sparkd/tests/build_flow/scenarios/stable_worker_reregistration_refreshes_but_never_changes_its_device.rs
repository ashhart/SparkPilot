#[test]
fn stable_worker_reregistration_refreshes_but_never_changes_its_device() {
    let harness = harness();
    let worker = Uuid::new_v4();
    let first = harness
        .service
        .register_worker(
            "Owner Mac",
            &harness.owner,
            "18.0",
            "macOS 27",
            &capabilities(1),
            Some(worker),
        )
        .unwrap();
    let refreshed = harness
        .service
        .register_worker(
            "Owner Mac renamed",
            &harness.owner,
            "18.1",
            "macOS 27.1",
            &capabilities(2),
            Some(worker),
        )
        .unwrap();
    assert_eq!(first.id, refreshed.id);
    let stored = harness
        .service
        .list_workers()
        .unwrap()
        .into_iter()
        .find(|candidate| candidate.id == worker)
        .unwrap();
    assert_eq!(stored.display_name, "Owner Mac renamed");
    assert_eq!(stored.xcode_version, "18.1");

    let other_device = Uuid::new_v4();
    assert_eq!(
        harness
            .service
            .register_worker(
                "Imposter",
                &other_device,
                "18.1",
                "macOS 27.1",
                &capabilities(2),
                Some(worker),
            )
            .err(),
        Some("BUILD_WORKER_ID_CONFLICT".into())
    );

    {
        let connection = harness.service.projects.db.lock();
        store::update_build_worker_state(&connection, &worker, "revoked").unwrap();
    }
    assert_eq!(
        harness
            .service
            .register_worker(
                "Owner Mac",
                &harness.owner,
                "18.1",
                "macOS 27.1",
                &capabilities(2),
                Some(worker),
            )
            .err(),
        Some("BUILD_WORKER_REVOKED".into())
    );
}
