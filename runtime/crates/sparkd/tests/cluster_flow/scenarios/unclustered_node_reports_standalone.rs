#[tokio::test]
async fn unclustered_node_reports_standalone() {
    let (state, client, _, _guard) =
        test_state("owner", healthy_report(), CollectiveOutcome::Passed);
    let (status, value) = send(
        state,
        signed_request(&client, "GET", "/api/v1/cluster", None),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(value["state"], "standalone");
    assert_eq!(value["members"].as_array().unwrap().len(), 0);
    assert_eq!(value["id"], Value::Null);
}
