#[tokio::test]
async fn a_project_without_a_container_gets_no_terminal() {
    let (h, addr, key, device_id) = harness().await;
    let client = reqwest::Client::new();
    let operation_id = create_through_api(&client, addr, &key, &device_id, "no-sandbox").await;
    assert_eq!(
        wait_op(&h.state, operation_id, Duration::from_secs(20)).await,
        "succeeded"
    );
    let project_id = h.projects.list().unwrap().remove(0).id.to_string();

    let (status, body) = signed_json(
        &client,
        addr,
        &key,
        &device_id,
        "POST",
        &format!("/api/v1/projects/{project_id}/terminals"),
        Some(json!({ "shell": "login" })),
    )
    .await;
    assert_eq!(status, reqwest::StatusCode::INTERNAL_SERVER_ERROR, "{body}");
    assert_eq!(body["error"]["code"], "PROJECT_SANDBOX_UNAVAILABLE");
    assert!(
        h.containers.calls().is_empty(),
        "nothing was launched: {:?}",
        h.containers.calls()
    );
}
