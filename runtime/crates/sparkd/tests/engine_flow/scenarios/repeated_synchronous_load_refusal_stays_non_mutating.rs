#[tokio::test]
async fn repeated_synchronous_load_refusal_stays_non_mutating() {
    let (h, addr, key, device_id) = harness(240 << 30).await;
    let client = reqwest::Client::new();
    let first_operation: uuid::Uuid = load_model(&client, addr, &key, &device_id, None).await["id"]
        .as_str()
        .and_then(|value| uuid::Uuid::parse_str(value).ok())
        .unwrap();
    wait_terminal(&h.state, first_operation, Duration::from_secs(10)).await;

    let idempotency_key = uuid::Uuid::new_v4().to_string();
    let body = previewed_apply_body(
        &client,
        addr,
        &key,
        &device_id,
        "POST",
        "/api/v1/inference/load",
        Some(json!({ "model_id": "example/model-32b", "profile_id": "balanced-16k" })),
    )
    .await
    .unwrap()
    .unwrap();
    let first = signed_json_with_idempotency(
        &client,
        addr,
        &key,
        &device_id,
        "POST",
        "/api/v1/inference/load",
        Some(body.clone()),
        Some(&idempotency_key),
    )
    .await;
    let replay = signed_json_with_idempotency(
        &client,
        addr,
        &key,
        &device_id,
        "POST",
        "/api/v1/inference/load",
        Some(body),
        Some(&idempotency_key),
    )
    .await;
    assert_eq!(first.0, reqwest::StatusCode::CONFLICT, "{}", first.1);
    assert_eq!(replay.0, first.0);
    assert_eq!(replay.1["error"]["code"], first.1["error"]["code"]);
    assert_eq!(first.1["error"]["code"], "ENGINE_ACTIVE");
}
