#[tokio::test]
async fn load_apply_requires_a_digest_without_poisoning_the_idempotency_key() {
    let (h, addr, key, device_id) = harness(240 << 30).await;
    let client = reqwest::Client::new();
    let request = json!({
        "model_id": "example/model-32b",
        "profile_id": "balanced-16k",
    });

    let apply_key = uuid::Uuid::new_v4().to_string();
    let (missing_status, missing) = signed_json_with_idempotency(
        &client,
        addr,
        &key,
        &device_id,
        "POST",
        "/api/v1/inference/load",
        Some(request.clone()),
        Some(&apply_key),
    )
    .await;
    assert_eq!(
        missing_status,
        reqwest::StatusCode::PRECONDITION_REQUIRED,
        "{missing}"
    );
    assert_eq!(missing["error"]["code"], "PREVIEW_REQUIRED");
    let operation_count: i64 = h
        .state
        .database
        .as_ref()
        .unwrap()
        .lock()
        .query_row("SELECT COUNT(*) FROM operations", [], |row| row.get(0))
        .unwrap();
    assert_eq!(
        operation_count, 0,
        "a refused apply must not create an operation"
    );

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
    assert_eq!(preview["action"], "load");
    assert_eq!(
        preview["target"]["node_id"],
        h.state.identity.node_id().to_string()
    );
    assert_eq!(preview["recipe"]["model_id"], "example/model-32b");
    assert_eq!(
        preview["evidence"]["required_memory_bytes"],
        101_000_000_000_u64
    );
    assert_eq!(preview["blockers"], json!([]));

    // Permit telemetry drift that leaves admission and reviewed consequences unchanged.
    h.available.store((239_u64) << 30, Ordering::Relaxed);
    let mut apply = request;
    apply.as_object_mut().unwrap().insert(
        "accepted_preview_digest".into(),
        preview["preview_digest"].clone(),
    );
    let (apply_status, apply_response) = signed_json_with_idempotency(
        &client,
        addr,
        &key,
        &device_id,
        "POST",
        "/api/v1/inference/load",
        Some(apply),
        Some(&apply_key),
    )
    .await;
    assert_eq!(
        apply_status,
        reqwest::StatusCode::ACCEPTED,
        "{apply_response}"
    );
}
