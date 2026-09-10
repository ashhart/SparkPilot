#[test]
fn expired_heartbeat_is_projected_offline() {
    let harness = harness();
    let worker = Uuid::new_v4();
    harness
        .service
        .register_worker(
            "Owner",
            &harness.owner,
            "18.0",
            "macOS 27",
            &capabilities(1),
            Some(worker),
        )
        .unwrap();
    harness
        .clock
        .advance(time::Duration::seconds(WORKER_LIVENESS_SECONDS + 1));
    let projected = harness
        .service
        .list_workers()
        .unwrap()
        .into_iter()
        .find(|item| item.id == worker)
        .unwrap();
    assert_eq!(projected.state, "offline");
}
