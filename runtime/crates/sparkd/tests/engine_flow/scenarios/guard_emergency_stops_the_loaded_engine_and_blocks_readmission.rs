#[tokio::test]
async fn guard_emergency_stops_the_loaded_engine_and_blocks_readmission() {
    let (h, addr, key, device_id) = harness(240 << 30).await;
    let client = reqwest::Client::new();

    // Calm guard wired over the real engine, then a loaded model.
    let source = Arc::new(AtomicU64::new(240 << 30));
    let guard = guard_over(
        &h.engine,
        source.clone(),
        h.state.database.clone().expect("db"),
    );
    guard.tick(std::time::Duration::from_secs(1), "node");

    let operation_id: uuid::Uuid = load_model(&client, addr, &key, &device_id, None).await["id"]
        .as_str()
        .and_then(|s| uuid::Uuid::parse_str(s).ok())
        .expect("load operation id");
    wait_terminal(&h.state, operation_id, Duration::from_secs(10)).await;
    assert!(h.engine.is_active(), "engine loaded before emergency");

    // Headroom collapses: the guard demands an immediate emergency stop.
    source.store(4 << 30, Ordering::Relaxed);
    let transition = guard.tick(std::time::Duration::from_secs(2), "node");
    assert_eq!(
        transition.map(|t| t.to),
        Some(spark_telemetry::PressureState::Emergency)
    );

    // The real engine must stop (loopback listener gone) and clear.
    let deadline = std::time::Instant::now() + Duration::from_secs(5);
    while h.engine.is_active() {
        assert!(
            std::time::Instant::now() < deadline,
            "engine did not stop after guard emergency"
        );
        tokio::time::sleep(Duration::from_millis(20)).await;
    }

    // The exact active profile was marked unsafe; readmission is blocked.
    let unsafe_flag = {
        let conn = h.state.database.as_ref().expect("db").lock();
        sparkd::guard::profile_is_unsafe(&conn, "example/model-32b", "balanced-16k")
            .expect("read unsafe flag")
    };
    assert!(unsafe_flag, "emergency must mark the profile unsafe");

    let (status, body) = signed_json(
        &client,
        addr,
        &key,
        &device_id,
        "POST",
        "/api/v1/inference/load",
        Some(json!({ "model_id": "example/model-32b", "profile_id": "balanced-16k" })),
    )
    .await;
    assert_eq!(status, reqwest::StatusCode::CONFLICT, "{body}");
    assert_eq!(body["error"]["code"], "MODEL_PROFILE_UNSAFE", "{body}");
}
