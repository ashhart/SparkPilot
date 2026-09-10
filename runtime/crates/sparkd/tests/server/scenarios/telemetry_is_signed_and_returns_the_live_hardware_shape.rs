#[tokio::test]
async fn telemetry_is_signed_and_returns_the_live_hardware_shape() {
    let (state, client) = test_state();
    let day = state.clock.now().date().to_string();
    let usage = spark_telemetry::UsageRecord::request(
        client.device_id.to_string(),
        "test/model",
        120,
        30,
        std::time::Duration::from_millis(20),
        std::time::Duration::from_millis(200),
    );
    spark_telemetry::record_daily(
        &state.database.as_ref().expect("telemetry database").lock(),
        &day,
        &usage,
    )
    .expect("seed usage");

    let unsigned = router(state.clone())
        .oneshot(
            Request::builder()
                .uri("/api/v1/telemetry")
                .body(axum::body::Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(unsigned.status(), StatusCode::UNAUTHORIZED);

    let (status, body) = get_json(state, &client, "/api/v1/telemetry").await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["api_version"], 1);
    assert_eq!(body["accelerator"]["utilisation"], 0.42);
    assert_eq!(body["accelerator"]["temperature_celsius"], 52.0);
    assert_eq!(body["accelerator"]["power_draw_watts"], 48.5);
    assert_eq!(body["accelerator"]["memory_used_bytes"], 34_359_738_368_u64);
    assert_eq!(
        body["accelerator"]["memory_total_bytes"],
        137_438_953_472_u64
    );
    assert_eq!(body["storage"]["total_bytes"], 1_000_000_000_000_u64);
    assert_eq!(body["storage"]["free_bytes"], 91_827_364_512_u64);
    assert_eq!(body["storage"]["used_bytes"], 908_172_635_488_u64);
    assert_eq!(
        body["system"]["unified_memory_used_bytes"],
        108_695_058_125_u64
    );
    assert_eq!(body["inference"]["state"], "unloaded");
    assert!(body["inference"]["queue_depth"].is_null());
    assert_eq!(body["system"]["memory_psi_some_avg10"], 0.0);
    assert_eq!(body["system"]["memory_psi_full_avg10"], 0.0);
    assert_eq!(body["usage"]["requests"], 1);
    // Report unmeasured failure counts as null rather than claiming zero failures.
    assert!(
        body["usage"]["failures"].is_null(),
        "a failure count nothing records was reported as a number"
    );
    assert_eq!(body["usage"]["total_tokens"], 150);
    assert!(body["observed_at"].as_str().is_some());
}

/// §41.5.2.1: a node with no memory guard says so rather than reporting a cool-sounding rung.
#[tokio::test]
async fn telemetry_and_status_report_no_thermal_rung_without_a_guard() {
    let (state, client) = test_state();
    for path in ["/api/v1/telemetry", "/api/v1/status"] {
        let (status, body) = get_json(state.clone(), &client, path).await;
        assert_eq!(status, StatusCode::OK, "{path}");
        assert_eq!(
            body["system"]["thermal_state"], "unavailable",
            "{path} must not imply a heat verdict it cannot make"
        );
        assert!(body["system"]["thermal_warning_celsius"].is_null(), "{path}");
        assert!(body["system"]["thermal_hot_celsius"].is_null(), "{path}");
        assert!(body["system"]["thermal_critical_celsius"].is_null(), "{path}");
    }
}
