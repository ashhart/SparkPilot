#[tokio::test]
async fn approval_merges_and_mark_change_merged() {
    let (h, addr, key, device_id) = harness(vec![
        AgentToolCall::WriteFile {
            path: "feature.txt".into(),
            content: "agent implementation\n".into(),
        },
        AgentToolCall::Git {
            op: GitOp::Add {
                path: "feature.txt".into(),
            },
        },
        AgentToolCall::Git {
            op: GitOp::Commit {
                message: "feature work".into(),
            },
        },
        AgentToolCall::RunCommand {
            command: "true".into(),
        },
    ])
    .await;
    let client = reqwest::Client::new();
    let project_id = create_project(&client, addr, &key, &device_id, &h.state, "approvals").await;

    let (_, response) = signed_json(
        &client,
        addr,
        &key,
        &device_id,
        "POST",
        &format!("/api/v1/projects/{project_id}/agents"),
        Some(json!({ "task": "implement the feature" })),
    )
    .await;
    let op = response["id"].as_str().unwrap().to_owned();
    wait_ok(&h.state, &op).await;
    let change = wait_change_status(&h.state, &project_id, "implement the feature", "review").await;

    let decision_key = uuid::Uuid::new_v4();
    let approval_path = format!(
        "/api/v1/projects/{project_id}/changes/{}/approve",
        change["id"].as_str().unwrap()
    );
    let approval_body = json!({
        "comment": "looks good",
        "review_digest": change["review_digest"],
    });
    let (status, approved) = signed_json_with_idempotency(
        &client,
        addr,
        &key,
        &device_id,
        "POST",
        &approval_path,
        Some(approval_body.clone()),
        decision_key,
    )
    .await;
    assert_eq!(status, reqwest::StatusCode::OK, "{approved}");
    assert_eq!(approved["change"]["status"], "merged");
    let (replay_status, replay) = signed_json_with_idempotency(
        &client,
        addr,
        &key,
        &device_id,
        "POST",
        &approval_path,
        Some(approval_body),
        decision_key,
    )
    .await;
    assert_eq!(replay_status, reqwest::StatusCode::OK);
    assert_eq!(replay, approved);
    let (service_replay_status, service_replay) = signed_json(
        &client,
        addr,
        &key,
        &device_id,
        "POST",
        &approval_path,
        Some(json!({
            "comment": "same reviewed evidence",
            "review_digest": change["review_digest"],
        })),
    )
    .await;
    assert_eq!(
        service_replay_status,
        reqwest::StatusCode::OK,
        "{service_replay}"
    );
    assert_eq!(service_replay["change"]["status"], "merged");

    // The worktree already got the agent files; approve merged it.
    let view = h
        .state
        .projects
        .manager
        .as_ref()
        .unwrap()
        .get(&uuid::Uuid::parse_str(&project_id).unwrap())
        .unwrap();
    assert!(view.root_path.join("feature.txt").exists());

    // The approval decision was recorded.
    let change_id = uuid::Uuid::parse_str(change["id"].as_str().unwrap()).unwrap();
    let conn = h.state.database.as_ref().unwrap().lock();
    let approval_count: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM approvals WHERE resource_id = ?1 AND status = 'approved'",
            rusqlite::params![change_id.to_string()],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(approval_count, 1);
}
