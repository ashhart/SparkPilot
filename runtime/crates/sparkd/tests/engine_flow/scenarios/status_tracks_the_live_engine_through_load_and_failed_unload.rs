#[tokio::test]
async fn status_tracks_the_live_engine_through_load_and_failed_unload() {
    let (h, addr, key, device_id) = harness(240 << 30).await;
    let client = reqwest::Client::new();

    let (_, active) = status_and_active_inference(&client, addr, &key, &device_id).await;
    assert_eq!(active["state"], "unloaded");

    let operation_id: uuid::Uuid = load_model(&client, addr, &key, &device_id, None).await["id"]
        .as_str()
        .and_then(|id| uuid::Uuid::parse_str(id).ok())
        .expect("load operation id");
    let terminal = wait_terminal(&h.state, operation_id, Duration::from_secs(10)).await;
    assert_eq!(terminal["state"], "succeeded", "{terminal}");

    // `idle` is the contract projection of a ready engine with no active requests.
    let (_, active) = status_and_active_inference(&client, addr, &key, &device_id).await;
    assert_eq!(active["state"], "idle");
    assert_eq!(active["model_id"], "example/model-32b");

    // Force stop failure with a surviving container and require failed status; delayed page-cache recovery alone is not an unload failure.
    h.backend.fail_next_stop();
    let (status, body) = signed_json(
        &client,
        addr,
        &key,
        &device_id,
        "POST",
        "/api/v1/inference/unload",
        Some(json!({})),
    )
    .await;
    assert_eq!(status, reqwest::StatusCode::ACCEPTED, "{body}");
    let operation_id = body["id"]
        .as_str()
        .and_then(|id| uuid::Uuid::parse_str(id).ok())
        .expect("unload operation id");
    let terminal = wait_terminal(&h.state, operation_id, Duration::from_secs(10)).await;
    assert_eq!(terminal["state"], "failed", "{terminal}");

    let (_, active) = status_and_active_inference(&client, addr, &key, &device_id).await;
    assert_eq!(active["state"], "failed");
    assert_eq!(active["model_id"], "example/model-32b");

    // Retain the failed instance so a fresh signed unload retries stop verification instead of returning MODEL_NOT_LOADED.
    let (retry_status, retry_body) = signed_json(
        &client,
        addr,
        &key,
        &device_id,
        "POST",
        "/api/v1/inference/unload",
        Some(json!({})),
    )
    .await;
    assert_eq!(retry_status, reqwest::StatusCode::ACCEPTED, "{retry_body}");
    let retry_id = retry_body["id"]
        .as_str()
        .and_then(|id| uuid::Uuid::parse_str(id).ok())
        .expect("retry unload operation id");
    let retried = wait_terminal(&h.state, retry_id, Duration::from_secs(10)).await;
    assert_eq!(retried["state"], "succeeded", "{retried}");
    let (_, active) = status_and_active_inference(&client, addr, &key, &device_id).await;
    assert_eq!(active["state"], "unloaded");
}
