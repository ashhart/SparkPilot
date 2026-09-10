#[tokio::test]
async fn tool_allowlist_blocks_arbitrary_commands() {
    let (h, addr, key, device_id) = harness(vec![AgentToolCall::RunCommand {
        command: "rm -rf /".into(),
    }])
    .await;
    let client = reqwest::Client::new();
    let project_id = create_project(&client, addr, &key, &device_id, &h.state, "policy").await;

    let (_, response) = signed_json(
        &client,
        addr,
        &key,
        &device_id,
        "POST",
        &format!("/api/v1/projects/{project_id}/agents"),
        Some(json!({ "task": "do something destructive" })),
    )
    .await;
    let op = response["id"].as_str().unwrap().to_owned();

    // The denied tool fails the change; the op records the failure.
    wait_until_failed(&h.state, &op).await;
    let change =
        wait_change_status(&h.state, &project_id, "do something destructive", "failed").await;
    let calls = h
        .agents
        .change_calls(&uuid::Uuid::parse_str(change["id"].as_str().unwrap()).unwrap())
        .unwrap();
    assert_eq!(calls.len(), 1);
    assert_eq!(calls[0].0, "run_command");
    assert_eq!(calls[0].2, "failed", "{calls:?}");
}
