/// Refuse analysis targets naming another node or cluster instead of silently serving on the receiving Spark.
#[tokio::test]
async fn text_analysis_refuses_a_target_that_is_not_this_runtime() {
    let (h, addr, owner, _observer) = harness().await;
    let client = reqwest::Client::new();
    load_model(&client, addr, &owner).await;

    let mut wrong_node = analysis_body("Whose Spark is this?");
    wrong_node["target"] = json!({ "node_id": uuid::Uuid::new_v4().to_string() });
    let (status, response) = post(
        &client,
        addr,
        &owner,
        "/api/v1/inference/analyses",
        wrong_node,
    )
    .await;
    assert_eq!(status, 409, "{response}");
    assert_eq!(response["error"]["code"], "TARGET_IDENTITY_MISMATCH");

    let mut cluster = analysis_body("Whose cluster is this?");
    cluster["target"] = json!({ "cluster_id": uuid::Uuid::new_v4().to_string() });
    let (status, response) =
        post(&client, addr, &owner, "/api/v1/inference/analyses", cluster).await;
    assert_eq!(status, 409, "{response}");
    assert_eq!(response["error"]["code"], "CLUSTER_INFERENCE_UNAVAILABLE");

    // Accept the correct node identity to prove target validation is selective.
    let mut right_node = analysis_body("This one is addressed correctly.");
    right_node["target"] = json!({ "node_id": h.state.identity.node_id().to_string() });
    let (status, response) = post(
        &client,
        addr,
        &owner,
        "/api/v1/inference/analyses",
        right_node,
    )
    .await;
    assert_eq!(status, 202, "{response}");
}
