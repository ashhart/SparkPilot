#[tokio::test]
async fn a_failed_test_never_reaches_review() {
    let mut plan = reviewed_file_plan("failing.txt", "not reviewed\n");
    *plan.last_mut().unwrap() = AgentToolCall::RunCommand {
        command: "false".into(),
    };
    let (h, addr, key, device_id) = harness(plan).await;
    let client = reqwest::Client::new();
    let project_id = create_project(&client, addr, &key, &device_id, &h.state, "failing").await;
    let (_, response) = signed_json(
        &client,
        addr,
        &key,
        &device_id,
        "POST",
        &format!("/api/v1/projects/{project_id}/agents"),
        Some(json!({ "task": "failing test" })),
    )
    .await;
    wait_until_failed(&h.state, response["id"].as_str().unwrap()).await;
    let change = wait_change_status(&h.state, &project_id, "failing test", "failed").await;
    assert!(change["review_digest"].is_null(), "{change}");
}
