#[tokio::test]
async fn load_requires_a_well_formed_idempotency_key() {
    let (_h, addr, key, device_id) = harness(240 << 30).await;
    let client = reqwest::Client::new();
    let body = json!({ "model_id": "example/model-32b", "profile_id": "balanced-16k" });

    let (missing_status, missing_body) = signed_json_with_idempotency(
        &client,
        addr,
        &key,
        &device_id,
        "POST",
        "/api/v1/inference/load",
        Some(body.clone()),
        None,
    )
    .await;
    assert_eq!(
        missing_status,
        reqwest::StatusCode::BAD_REQUEST,
        "{missing_body}"
    );
    assert_eq!(missing_body["error"]["code"], "IDEMPOTENCY_KEY_REQUIRED");

    let (invalid_status, invalid_body) = signed_json_with_idempotency(
        &client,
        addr,
        &key,
        &device_id,
        "POST",
        "/api/v1/inference/load",
        Some(body),
        Some("not-a-uuid"),
    )
    .await;
    assert_eq!(
        invalid_status,
        reqwest::StatusCode::BAD_REQUEST,
        "{invalid_body}"
    );
    assert_eq!(invalid_body["error"]["code"], "IDEMPOTENCY_KEY_INVALID");
}
