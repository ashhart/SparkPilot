#[tokio::test]
async fn a_change_without_passing_test_evidence_never_reaches_review() {
    let (h, addr, key, device_id) = harness(vec![
        AgentToolCall::WriteFile {
            path: "untested.txt".into(),
            content: "not reviewed\n".into(),
        },
        AgentToolCall::Git {
            op: GitOp::Add {
                path: "untested.txt".into(),
            },
        },
        AgentToolCall::Git {
            op: GitOp::Commit {
                message: "untested change".into(),
            },
        },
    ])
    .await;
    let client = reqwest::Client::new();
    let project_id = create_project(&client, addr, &key, &device_id, &h.state, "untested").await;
    let (_, response) = signed_json(
        &client,
        addr,
        &key,
        &device_id,
        "POST",
        &format!("/api/v1/projects/{project_id}/agents"),
        Some(json!({ "task": "no test evidence" })),
    )
    .await;
    wait_until_failed(&h.state, response["id"].as_str().unwrap()).await;
    let change = wait_change_status(&h.state, &project_id, "no test evidence", "failed").await;
    assert!(change["review_digest"].is_null(), "{change}");
    assert_ne!(change["status"], "review");
}
