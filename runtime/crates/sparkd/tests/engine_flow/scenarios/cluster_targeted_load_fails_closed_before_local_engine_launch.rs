#[tokio::test]
async fn cluster_targeted_load_fails_closed_before_local_engine_launch() {
    let (h, addr, key, device_id) = clustered_harness(240 << 30).await;
    let client = reqwest::Client::new();
    let cluster_id = h
        .state
        .cluster
        .as_ref()
        .expect("cluster service")
        .status()
        .expect("cluster status")
        .id
        .expect("cluster id");
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
    assert_eq!(preview["target"]["cluster_id"], cluster_id);
    assert_eq!(
        preview["blockers"][0]["code"],
        "CLUSTER_INFERENCE_UNAVAILABLE"
    );
    assert_eq!(
        preview["blockers"][0]["owner_explanation"],
        "Distributed inference is unavailable because this runtime has no qualified cluster launch backend."
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
    assert_eq!(
        apply_status,
        reqwest::StatusCode::CONFLICT,
        "{apply_response}"
    );
    assert_eq!(
        apply_response["error"]["code"],
        "CLUSTER_INFERENCE_UNAVAILABLE"
    );
    assert!(h.engine.view().is_none(), "local vLLM must not start");
    let database = h.state.database.as_ref().expect("db").lock();
    let operation_count: i64 = database
        .query_row("SELECT COUNT(*) FROM operations", [], |row| row.get(0))
        .unwrap();
    assert_eq!(operation_count, 0, "blocked load created an operation");
    let refusal: String = database
        .query_row(
            "SELECT details_json FROM audit_records
              WHERE action = 'model.load' AND result = 'refused'
              ORDER BY sequence DESC LIMIT 1",
            [],
            |row| row.get(0),
        )
        .expect("cluster load refusal audit");
    assert_eq!(
        serde_json::from_str::<Value>(&refusal).unwrap(),
        json!({ "reason_code": "CLUSTER_INFERENCE_UNAVAILABLE" })
    );
}
