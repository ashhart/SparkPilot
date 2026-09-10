/// Pre-existing: request-changes and reject had byte-identical bodies, so asking for corrections rejected the change for good.
#[tokio::test]
async fn requesting_changes_preserves_audit_and_returns_the_change_to_editing() {
    let (h, addr, key, device_id) = harness(vec![
        AgentToolCall::WriteFile {
            path: "wip.txt".into(),
            content: "half-done\n".into(),
        },
        AgentToolCall::Git {
            op: GitOp::Add {
                path: "wip.txt".into(),
            },
        },
        AgentToolCall::Git {
            op: GitOp::Commit {
                message: "work needing review".into(),
            },
        },
        AgentToolCall::RunCommand {
            command: "true".into(),
        },
    ])
    .await;
    let client = reqwest::Client::new();
    let project_id = create_project(&client, addr, &key, &device_id, &h.state, "rejects").await;

    let (_, response) = signed_json(
        &client,
        addr,
        &key,
        &device_id,
        "POST",
        &format!("/api/v1/projects/{project_id}/agents"),
        Some(json!({ "task": "wip without commit" })),
    )
    .await;
    let op = response["id"].as_str().unwrap().to_owned();
    wait_ok(&h.state, &op).await;
    let change = wait_change_status(&h.state, &project_id, "wip without commit", "review").await;

    let change_id = change["id"].as_str().unwrap();
    let decision_key = uuid::Uuid::new_v4();
    let reject_path = format!("/api/v1/projects/{project_id}/changes/{change_id}/request-changes");
    let reject_body = json!({
        "comment": "needs more work",
        "review_digest": change["review_digest"],
    });
    let (status, rejected) = signed_json_with_idempotency(
        &client,
        addr,
        &key,
        &device_id,
        "POST",
        &reject_path,
        Some(reject_body.clone()),
        decision_key,
    )
    .await;
    assert_eq!(status, reqwest::StatusCode::OK, "{rejected}");
    assert_eq!(
        rejected["change"]["status"], "editing",
        "requesting changes must return the change to the agent, not close it"
    );
    let (replay_status, replay) = signed_json_with_idempotency(
        &client,
        addr,
        &key,
        &device_id,
        "POST",
        &reject_path,
        Some(reject_body),
        decision_key,
    )
    .await;
    assert_eq!(replay_status, reqwest::StatusCode::OK);
    assert_eq!(replay, rejected);

    let preserved = h
        .agents
        .get_change(&uuid::Uuid::parse_str(change_id).unwrap())
        .unwrap();
    assert_eq!(
        preserved.review_digest.as_deref(),
        change["review_digest"].as_str()
    );
    assert_eq!(
        preserved.review_evidence_json,
        change["review_evidence_json"]
            .as_str()
            .unwrap_or(&preserved.review_evidence_json)
    );
    let worktree = h
        .agents
        .projects
        .worktree_path_for_branch(&preserved.worktree_branch)
        .unwrap();
    assert!(
        worktree.join("wip.txt").exists(),
        "request changes preserves the reviewed worktree"
    );

    // Audit is preserved and the agent's commit never touched main.
    let calls = h
        .agents
        .change_calls(&uuid::Uuid::parse_str(change_id).unwrap())
        .unwrap();
    assert!(!calls.is_empty(), "audit preserved");
    let view = h
        .state
        .projects
        .manager
        .as_ref()
        .unwrap()
        .get(&uuid::Uuid::parse_str(&project_id).unwrap())
        .unwrap();
    assert!(
        !view.root_path.join("wip.txt").exists(),
        "a change awaiting corrections is not merged"
    );
    let requested: i64 = h
        .state
        .database
        .as_ref()
        .unwrap()
        .lock()
        .query_row(
            "SELECT COUNT(*) FROM events WHERE event_type = 'change.changes_requested'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(requested, 1, "the correction request was not published");

    // A change not in review cannot be approved again.
    let (status, conflict) = signed_json(
        &client,
        addr,
        &key,
        &device_id,
        "POST",
        &format!("/api/v1/projects/{project_id}/changes/{change_id}/approve"),
        Some(json!({ "review_digest": change["review_digest"] })),
    )
    .await;
    assert_eq!(status, reqwest::StatusCode::CONFLICT, "{conflict}");
    assert_eq!(conflict["error"]["code"], "CHANGE_NOT_IN_REVIEW");
}
