/// Reject is the terminal decision: the change closes and its evidence stays for the record.
#[tokio::test]
async fn rejection_closes_the_change_and_keeps_its_evidence() {
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
    let project_id = create_project(&client, addr, &key, &device_id, &h.state, "closes").await;

    let (_, response) = signed_json(
        &client,
        addr,
        &key,
        &device_id,
        "POST",
        &format!("/api/v1/projects/{project_id}/agents"),
        Some(json!({ "task": "work to close" })),
    )
    .await;
    let op = response["id"].as_str().unwrap().to_owned();
    wait_ok(&h.state, &op).await;
    let change = wait_change_status(&h.state, &project_id, "work to close", "review").await;
    let change_id = change["id"].as_str().unwrap();

    let (status, rejected) = signed_json(
        &client,
        addr,
        &key,
        &device_id,
        "POST",
        &format!("/api/v1/projects/{project_id}/changes/{change_id}/reject"),
        Some(json!({
            "comment": "not the right approach",
            "review_digest": change["review_digest"],
        })),
    )
    .await;
    assert_eq!(status, reqwest::StatusCode::OK, "{rejected}");
    assert_eq!(rejected["change"]["status"], "rejected");

    let preserved = h
        .agents
        .get_change(&uuid::Uuid::parse_str(change_id).unwrap())
        .unwrap();
    assert_eq!(
        preserved.review_digest.as_deref(),
        change["review_digest"].as_str(),
        "the reviewed evidence was discarded"
    );
    assert!(
        !h.agents
            .change_calls(&uuid::Uuid::parse_str(change_id).unwrap())
            .unwrap()
            .is_empty(),
        "the tool audit was discarded"
    );

    // A closed change cannot be approved and cannot be sent back for corrections.
    for route in ["approve", "request-changes"] {
        let (status, conflict) = signed_json(
            &client,
            addr,
            &key,
            &device_id,
            "POST",
            &format!("/api/v1/projects/{project_id}/changes/{change_id}/{route}"),
            Some(json!({
                "comment": "reopen please",
                "review_digest": change["review_digest"],
            })),
        )
        .await;
        assert_eq!(status, reqwest::StatusCode::CONFLICT, "{route}: {conflict}");
        assert_eq!(conflict["error"]["code"], "CHANGE_NOT_IN_REVIEW");
    }
}
