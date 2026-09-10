#[tokio::test]
async fn a_partly_unreadable_answer_is_reported_as_incomplete() {
    let harness = harness("owner", true);
    *harness.scripted_workloads.lock().unwrap() = Some(ObservedWorkloads {
        containers: vec![container("9f2c", Some("readable"), Some("acme/x:1"))],
        truncated: false,
        unreadable_lines: 2,
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
        "a list missing rows this build could not read is not the whole host"
    );
}
