#[tokio::test]
async fn single_node_recovery_preview_goes_stale_if_cluster_recovers_before_apply() {
    let (h, addr, key, device_id) = clustered_harness(240 << 30).await;
    let client = reqwest::Client::new();
    let cluster_id = seed_degraded_cluster_recovery(&h, device_id);
    let request = json!({
        "model_id": "example/model-32b",
        "profile_id": "balanced-16k",
        "target": {
            "node_id": h.state.identity.node_id().to_string(),
            "cluster_id": cluster_id,
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
    assert_eq!(preview["blockers"], json!([]));
    h.state
        .database
        .as_ref()
        .expect("db")
        .lock()
        .execute(
            "UPDATE cluster_state SET state='ready' WHERE id=?1",
            [&cluster_id],
        )
        .expect("recover cluster before apply");

    let mut apply = request;
    apply.as_object_mut().unwrap().insert(
        "accepted_preview_digest".into(),
        preview["preview_digest"].clone(),
    );
    let (apply_status, response) = signed_json_with_idempotency(
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
    assert_eq!(apply_status, reqwest::StatusCode::CONFLICT, "{response}");
    assert_eq!(response["error"]["code"], "PREVIEW_STALE");
    assert_eq!(h.backend.launches(), 0, "stale recovery never launched");
}
