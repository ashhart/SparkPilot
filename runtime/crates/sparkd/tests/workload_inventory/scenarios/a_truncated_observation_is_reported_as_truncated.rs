#[tokio::test]
async fn a_truncated_observation_is_reported_as_truncated() {
    let harness = harness("owner", true);
    *harness.scripted_workloads.lock().unwrap() = Some(ObservedWorkloads {
        containers: vec![container("9f2c", Some("one-of-many"), Some("acme/x:1"))],
        truncated: true,
        unreadable_lines: 0,
    });

    let (status, body) = send(
        harness.state,
        signed_get(&harness.client, "/api/v1/workloads"),
    )
    .await;

    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["available"], true);
    assert_eq!(
        body["truncated"], true,
        "an incomplete list must not read as the whole host"
    );
}
