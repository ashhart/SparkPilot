#[tokio::test]
async fn a_reused_load_key_with_a_different_signed_body_conflicts() {
    let (_h, addr, key, device_id) = harness(240 << 30).await;
    let client = reqwest::Client::new();
    let idempotency_key = uuid::Uuid::new_v4().to_string();
    let original = previewed_apply_body(
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
    let changed = json!({
        "model_id": "example/model-32b",
        "profile_id": "balanced-16k",
        "replace_active": true
    });

    let (first_status, first_body) = signed_json_with_idempotency(
        &client,
        addr,
        &key,
        &device_id,
        "POST",
        "/api/v1/inference/load",
        Some(original),
        Some(&idempotency_key),
    )
    .await;
    assert_eq!(first_status, reqwest::StatusCode::ACCEPTED, "{first_body}");

    let (changed_status, changed_body) = signed_json_with_idempotency(
        &client,
        addr,
        &key,
        &device_id,
        "POST",
        "/api/v1/inference/load",
        Some(changed),
        Some(&idempotency_key),
    )
    .await;
    assert_eq!(
        changed_status,
        reqwest::StatusCode::CONFLICT,
        "{changed_body}"
    );
    assert_eq!(changed_body["error"]["code"], "IDEMPOTENCY_KEY_REUSED");
}
