#[tokio::test]
async fn an_uninspectable_host_is_not_reported_as_an_idle_one() {
    // Report uninspectable inventory as unavailable instead of implying the host is idle.
    let harness = harness("owner", true);

    let (status, body) = send(
        harness.state,
        signed_get(&harness.client, "/api/v1/workloads"),
    )
    .await;

    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["available"], false);
    assert!(body["unavailable_reason"].is_string());
    assert_eq!(body["workloads"].as_array().map(Vec::len), Some(0));
}
