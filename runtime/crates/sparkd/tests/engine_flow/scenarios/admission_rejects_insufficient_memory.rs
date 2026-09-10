#[tokio::test]
async fn admission_rejects_insufficient_memory() {
    let (h, addr, key, device_id) = harness(100 << 30).await; // below reserve+peak
    let client = reqwest::Client::new();

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
    assert_eq!(body["error"]["code"], "MODEL_INSUFFICIENT_MEMORY", "{body}");
    let _ = &h.available;
}
