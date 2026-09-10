#[tokio::test]
async fn load_apply_rejects_a_changed_capacity_decision() {
    let (h, addr, key, device_id) = harness(240 << 30).await;
    let client = reqwest::Client::new();
    let request = json!({
        "model_id": "example/model-32b",
        "profile_id": "balanced-16k",
    });
    let (preview_status, preview) = signed_json_with_idempotency(
        &client,
        addr,
        &key,
        &device_id,
        "POST",
        "/api/v1/inference/load/preview",
        Some(request.clone()),
        Some(&uuid::Uuid::new_v4().to_string()),
    )
    .await;
    assert_eq!(preview_status, reqwest::StatusCode::OK, "{preview}");

    h.available.store(90_u64 << 30, Ordering::Relaxed);
    let mut apply = request;
    apply.as_object_mut().unwrap().insert(
        "accepted_preview_digest".into(),
        preview["preview_digest"].clone(),
    );
    let (status, response) = signed_json_with_idempotency(
        &client,
        addr,
        &key,
        &device_id,
        "POST",
        "/api/v1/inference/load",
        Some(apply),
        Some(&uuid::Uuid::new_v4().to_string()),
    )
    .await;
    assert_eq!(status, reqwest::StatusCode::CONFLICT, "{response}");
    assert_eq!(response["error"]["code"], "PREVIEW_STALE");
    assert!(h.engine.view().is_none());
}
