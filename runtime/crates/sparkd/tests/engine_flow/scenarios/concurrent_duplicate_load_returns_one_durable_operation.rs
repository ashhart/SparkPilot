#[tokio::test]
async fn concurrent_duplicate_load_returns_one_durable_operation() {
    let (h, addr, key, device_id) = harness(240 << 30).await;
    let client = reqwest::Client::new();
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
    );
    let second = signed_json_with_idempotency(
        &client,
        addr,
        &key,
        &device_id,
        "POST",
        "/api/v1/inference/load",
        Some(body),
        Some(&idempotency_key),
    );
    let ((first_status, first_body), (second_status, second_body)) = tokio::join!(first, second);

    assert_eq!(first_status, reqwest::StatusCode::ACCEPTED, "{first_body}");
    assert_eq!(
        second_status,
        reqwest::StatusCode::ACCEPTED,
        "{second_body}"
    );
    assert_eq!(
        first_body, second_body,
        "a replay must return the original response"
    );
    let operation_count: i64 = h
        .state
        .database
        .as_ref()
        .expect("db")
        .lock()
        .query_row("SELECT COUNT(*) FROM operations", [], |row| row.get(0))
        .unwrap();
    assert_eq!(
        operation_count, 1,
        "duplicate request created another operation"
    );
}
