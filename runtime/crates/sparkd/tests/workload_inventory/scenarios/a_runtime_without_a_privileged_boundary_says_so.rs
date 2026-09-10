#[tokio::test]
async fn a_runtime_without_a_privileged_boundary_says_so() {
    let harness = harness("owner", false);

    let (status, body) = send(
        harness.state,
        signed_get(&harness.client, "/api/v1/workloads"),
    )
    .await;

    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["available"], false);
    assert_eq!(body["adoption_supported"], false);
    assert_eq!(body["workloads"].as_array().map(Vec::len), Some(0));
}
