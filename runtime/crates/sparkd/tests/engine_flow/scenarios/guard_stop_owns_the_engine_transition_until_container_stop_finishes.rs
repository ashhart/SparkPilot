#[tokio::test]
async fn guard_stop_owns_the_engine_transition_until_container_stop_finishes() {
    let (h, addr, key, device_id) = harness(240 << 30).await;
    let client = reqwest::Client::new();
    let source = Arc::new(AtomicU64::new(240 << 30));
    let guard = guard_over(
        &h.engine,
        source.clone(),
        h.state.database.clone().expect("db"),
    );
    guard.tick(std::time::Duration::from_secs(1), "node");

    let operation_id: uuid::Uuid = load_model(&client, addr, &key, &device_id, None).await["id"]
        .as_str()
        .expect("load operation id")
        .parse()
        .expect("load operation uuid");
    wait_terminal(&h.state, operation_id, Duration::from_secs(10)).await;

    h.backend.set_stop_blocked(true);
    source.store(4 << 30, Ordering::Relaxed);
    let transition = guard.tick(std::time::Duration::from_secs(2), "node");
    assert_eq!(
        transition.map(|transition| transition.to),
        Some(spark_telemetry::PressureState::Emergency)
    );
    let deadline = std::time::Instant::now() + Duration::from_secs(2);
    while !h.backend.stop_started() {
        assert!(
            std::time::Instant::now() < deadline,
            "guard-driven container stop did not start"
        );
        tokio::time::sleep(Duration::from_millis(10)).await;
    }

    assert!(
        h.engine.is_transitioning(),
        "the memory guard must keep exclusive ownership while stop is in flight"
    );
    assert!(h.engine.resume_guard_drain().is_err());
    assert!(h.engine.begin_request().is_err());
    h.backend.set_stop_blocked(false);
}
