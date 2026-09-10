#[tokio::test]
async fn admission_blocks_while_pressure_is_active() {
    let (h, addr, key, device_id) = harness(240 << 30).await;
    let client = reqwest::Client::new();

    // Place the guard at Warning before load and require canonical admission to refuse.
    let source = Arc::new(AtomicU64::new(15 << 30)); // warning band
    let guard = guard_over(
        &h.engine,
        source.clone(),
        h.state.database.clone().expect("db"),
    );
    // Escalation needs the minimum duration (3 s) in the warning band.
    guard.tick(std::time::Duration::from_secs(1), "node");
    guard.tick(std::time::Duration::from_secs(4), "node");
    assert_eq!(
        guard.reading().state,
        spark_telemetry::PressureState::Warning
    );

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
    assert_eq!(body["error"]["code"], "MEMORY_PRESSURE_ACTIVE", "{body}");
}
