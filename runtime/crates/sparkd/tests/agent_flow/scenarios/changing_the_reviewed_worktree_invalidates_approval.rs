#[tokio::test]
async fn changing_the_reviewed_worktree_invalidates_approval() {
    let (h, addr, key, device_id) = harness(reviewed_file_plan("stale.txt", "reviewed\n")).await;
    let client = reqwest::Client::new();
    let project_id = create_project(&client, addr, &key, &device_id, &h.state, "stale").await;
    let (_, started) = signed_json(
        &client,
        addr,
        &key,
        &device_id,
        "POST",
        &format!("/api/v1/projects/{project_id}/agents"),
        Some(json!({ "task": "stale checkout" })),
    )
    .await;
    wait_ok(&h.state, started["id"].as_str().unwrap()).await;
    let change = wait_change_status(&h.state, &project_id, "stale checkout", "review").await;
    let worktree = h
        .agents
        .projects
        .worktree_path_for_branch(change["worktree_branch"].as_str().unwrap())
        .unwrap();
    std::fs::write(worktree.join("stale.txt"), "changed after review\n").unwrap();
    let (status, body) = signed_json(
        &client,
        addr,
        &key,
        &device_id,
        "POST",
        &format!(
            "/api/v1/projects/{project_id}/changes/{}/approve",
            change["id"].as_str().unwrap()
        ),
        Some(json!({ "review_digest": change["review_digest"] })),
    )
    .await;
    assert_eq!(status, reqwest::StatusCode::CONFLICT, "{body}");
    assert_eq!(body["error"]["code"], "REVIEW_EVIDENCE_STALE");
}
