#[tokio::test]
async fn ready_load_records_observed_profile_memory_for_future_admission() {
    let (h, addr, key, device_id) = harness(240 << 30).await;
    let client = reqwest::Client::new();
    h.backend.set_readiness_blocked(true);

    let operation_id: uuid::Uuid = load_model(&client, addr, &key, &device_id, None).await["id"]
        .as_str()
        .expect("load operation id")
        .parse()
        .expect("operation uuid");
    let deadline = std::time::Instant::now() + Duration::from_secs(2);
    while !h.backend.readiness_started() {
        assert!(
            std::time::Instant::now() < deadline,
            "readiness probing did not start"
        );
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    h.available.store(180 << 30, Ordering::Relaxed);
    h.backend.set_readiness_blocked(false);

    let terminal = wait_terminal(&h.state, operation_id, Duration::from_secs(10)).await;
    assert_eq!(terminal["state"], "succeeded", "{terminal}");
    let measured = sparkd::guard::measured_peak(
        &h.state.database.as_ref().expect("db").lock(),
        "example/model-32b",
        "balanced-16k",
        &fixture_environment(),
    )
    .expect("measured peak query");
    assert_eq!(measured, Some(60 << 30));
}

#[tokio::test]
async fn host_watermarks_are_not_counted_twice_but_allocated_memory_is() {
    for (reported, expected) in [
        (16 << 30, 44 << 30),
        (u64::MAX, (60 << 30) - RecipeFixture::example().memory.minimum_system_reserve_bytes),
    ] {
    let (h, addr, key, device_id) = harness(240 << 30).await;
    let client = reqwest::Client::new();
    h.backend.set_readiness_blocked(true);
    h.backend.set_host_reserve(reported);

    let operation_id: uuid::Uuid = load_model(&client, addr, &key, &device_id, None).await["id"]
        .as_str()
        .expect("load operation id")
        .parse()
        .expect("operation uuid");
    let deadline = std::time::Instant::now() + Duration::from_secs(2);
    while !h.backend.readiness_started() {
        assert!(
            std::time::Instant::now() < deadline,
            "readiness probing did not start"
        );
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    h.available.store(180 << 30, Ordering::Relaxed);
    h.backend.set_readiness_blocked(false);

    let terminal = wait_terminal(&h.state, operation_id, Duration::from_secs(10)).await;
    assert_eq!(terminal["state"], "succeeded", "{terminal}");
    let measured = sparkd::guard::measured_peak(
        &h.state.database.as_ref().expect("db").lock(),
        "example/model-32b",
        "balanced-16k",
        &fixture_environment(),
    )
    .expect("measured peak query");
    assert_eq!(measured, Some(expected));
    }
}
