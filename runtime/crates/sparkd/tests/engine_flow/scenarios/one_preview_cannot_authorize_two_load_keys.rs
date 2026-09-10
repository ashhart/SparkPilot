#[tokio::test]
async fn one_preview_cannot_authorize_two_load_keys() {
    let (h, addr, key, device_id) = harness(240 << 30).await;
    let client = reqwest::Client::new();
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

    let (first_status, first) = signed_json_with_idempotency(
        &client,
        addr,
        &key,
        &device_id,
        "POST",
        "/api/v1/inference/load",
        Some(body.clone()),
        Some(&uuid::Uuid::new_v4().to_string()),
    )
    .await;
    assert_eq!(first_status, reqwest::StatusCode::ACCEPTED, "{first}");

    let (second_status, second) = signed_json_with_idempotency(
        &client,
        addr,
        &key,
        &device_id,
        "POST",
        "/api/v1/inference/load",
        Some(body),
        Some(&uuid::Uuid::new_v4().to_string()),
    )
    .await;
    assert_eq!(second_status, reqwest::StatusCode::CONFLICT, "{second}");
    assert_eq!(second["error"]["code"], "PREVIEW_ALREADY_ACCEPTED");
    let operation_count: i64 = h
        .state
        .database
        .as_ref()
        .unwrap()
        .lock()
        .query_row("SELECT COUNT(*) FROM operations", [], |row| row.get(0))
        .unwrap();
    assert_eq!(operation_count, 1);
}
