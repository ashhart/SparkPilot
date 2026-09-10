#[tokio::test]
async fn agent_runs_tools_and_reaches_review_with_diff() {
    let (h, addr, key, device_id) = harness(vec![
        AgentToolCall::WriteFile {
            path: "greetings.txt".into(),
            content: "hello from the agent\n".into(),
        },
        AgentToolCall::Git {
            op: GitOp::Add {
                path: "greetings.txt".into(),
            },
        },
        AgentToolCall::Git {
            op: GitOp::Commit {
                message: "add greeting".into(),
            },
        },
        AgentToolCall::RunCommand {
            command: "true".into(),
        },
    ])
    .await;
    let client = reqwest::Client::new();
    let project_id = create_project(&client, addr, &key, &device_id, &h.state, "agents").await;

    let (status, response) = signed_json(
        &client,
        addr,
        &key,
        &device_id,
        "POST",
        &format!("/api/v1/projects/{project_id}/agents"),
        Some(json!({ "task": "add a greeting file" })),
    )
    .await;
    assert_eq!(status, reqwest::StatusCode::ACCEPTED, "{response}");
    let op = response["id"].as_str().unwrap().to_owned();
    wait_ok(&h.state, &op).await;

    let change = wait_change_status(&h.state, &project_id, "add a greeting file", "review").await;
    assert_ne!(
        change["worktree_branch"].as_str().unwrap_or(""),
        "",
        "{change}"
    );

    // Every tool call was audited, in order.
    let calls = h
        .agents
        .change_calls(&uuid::Uuid::parse_str(change["id"].as_str().unwrap()).unwrap())
        .unwrap();
    assert_eq!(calls.len(), 4, "{calls:?}");
    assert_eq!(calls[0].0, "write_file");
    assert_eq!(calls[1].0, "git");
    assert_eq!(calls[2].0, "git");
    assert_eq!(calls[3].0, "run_command");

    // The change list exposes the review row (not the worktree contents).
    let (status, changes) = signed_json(
        &client,
        addr,
        &key,
        &device_id,
        "GET",
        &format!("/api/v1/projects/{project_id}/changes"),
        None,
    )
    .await;
    assert_eq!(status, reqwest::StatusCode::OK, "{changes}");
    assert_eq!(changes["items"][0]["status"], "review");
    assert_eq!(changes["items"][0]["task"], "add a greeting file");
    assert_eq!(changes["items"][0]["evidence_complete"], true);
    assert_eq!(
        changes["items"][0]["changed_files"][0]["path"],
        "greetings.txt"
    );
    assert_eq!(changes["items"][0]["test_evidence"][0]["status"], "passed");
    assert_eq!(
        changes["items"][0]["review_digest"].as_str().unwrap().len(),
        64
    );
}
