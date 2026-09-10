/// A worker whose heartbeat lapsed is announced, and only on the transition, not on every sweep.
#[test]
fn a_worker_that_stops_beating_is_announced_offline_once() {
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
    let mut events = harness.state.events.subscribe();
    harness
        .clock
        .advance(time::Duration::seconds(WORKER_LIVENESS_SECONDS + 1));
    harness.service.requeue_expired().unwrap();
    harness.service.requeue_expired().unwrap();

    let mut offline = 0;
    while let Ok(event) = events.try_recv() {
        if event["type"] == "build.worker.offline" {
            assert_eq!(event["payload"]["worker_id"], worker.to_string());
            offline += 1;
        }
    }
    assert_eq!(offline, 1, "one transition, one event");
    let stored = harness
        .service
        .list_workers()
        .unwrap()
        .into_iter()
        .find(|item| item.id == worker)
        .unwrap();
    assert_eq!(stored.state, "offline");
}
