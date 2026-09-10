#[tokio::test]
async fn standalone_load_carrying_a_cluster_id_reports_cluster_inference_unavailable() {
    let (h, addr, key, device_id) = harness(240 << 30).await;
    let client = reqwest::Client::new();
    let request = json!({
        "model_id": "example/model-32b",
        "profile_id": "balanced-16k",
        "target": {
            "node_id": h.state.identity.node_id().to_string(),
            "cluster_id": uuid::Uuid::new_v4().to_string(),
        },
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
    assert_eq!(
        preview["blockers"][0]["code"],
        "CLUSTER_INFERENCE_UNAVAILABLE"
    );

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
        Some(&uuid::Uuid::new_v4().to_string()),
    )
    .await;

    assert_eq!(apply_status, reqwest::StatusCode::CONFLICT);
    assert_eq!(
        apply_response["error"]["code"],
        "CLUSTER_INFERENCE_UNAVAILABLE"
    );
    assert!(h.engine.view().is_none(), "local vLLM must not start");
    let operation_count: i64 = h
        .state
        .database
        .as_ref()
        .expect("db")
        .lock()
        .query_row("SELECT COUNT(*) FROM operations", [], |row| row.get(0))
        .unwrap();
    assert_eq!(operation_count, 0, "blocked load created an operation");
}
