#[tokio::test]
async fn a_stopped_degraded_cluster_can_launch_an_exact_signed_single_node_recovery() {
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
    assert_eq!(preview["blockers"], json!([]), "{preview}");

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
    assert_eq!(apply_status, reqwest::StatusCode::ACCEPTED, "{response}");
    let operation_id = response["id"]
        .as_str()
        .expect("load operation id")
        .parse()
        .expect("load operation uuid");
    let terminal = wait_terminal(&h.state, operation_id, Duration::from_secs(10)).await;
    assert_eq!(terminal["state"], "succeeded", "{terminal}");
    assert_eq!(
        h.backend.launches(),
        1,
        "local recovery engine launched once"
    );
    let connection = h.state.database.as_ref().expect("db").lock();
    let cluster_state: String = connection
        .query_row(
            "SELECT state FROM cluster_state WHERE id=?1",
            [cluster_id],
            |row| row.get(0),
        )
        .expect("retained cluster state");
    assert_eq!(cluster_state, "degraded", "recovery retained diagnostics");
    let distributed_state: String = connection
        .query_row(
            "SELECT state FROM cluster_launches ORDER BY created_at DESC LIMIT 1",
            [],
            |row| row.get(0),
        )
        .expect("distributed launch journal");
    assert_eq!(distributed_state, "stopped");
}
