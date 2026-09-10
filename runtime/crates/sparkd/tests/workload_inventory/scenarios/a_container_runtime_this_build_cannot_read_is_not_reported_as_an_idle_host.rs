#[tokio::test]
async fn a_container_runtime_this_build_cannot_read_is_not_reported_as_an_idle_host() {
    // Treat successful but unreadable container-runtime output as unavailable, never as an idle empty host.
    let harness = harness("owner", true);
    *harness.scripted_workloads.lock().unwrap() = Some(ObservedWorkloads {
        containers: Vec::new(),
        truncated: false,
        unreadable_lines: 7,
    });

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
