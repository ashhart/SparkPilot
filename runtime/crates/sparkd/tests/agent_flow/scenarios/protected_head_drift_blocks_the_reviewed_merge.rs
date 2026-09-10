#[tokio::test]
async fn protected_head_drift_blocks_the_reviewed_merge() {
    let (h, addr, key, device_id) = harness(reviewed_file_plan("drift.txt", "reviewed\n")).await;
    let client = reqwest::Client::new();
    let project_id = create_project(&client, addr, &key, &device_id, &h.state, "drift").await;
    let (_, started) = signed_json(
        &client,
        addr,
        &key,
        &device_id,
        "POST",
        &format!("/api/v1/projects/{project_id}/agents"),
        Some(json!({ "task": "protected drift" })),
    )
    .await;
    wait_ok(&h.state, started["id"].as_str().unwrap()).await;
    let change = wait_change_status(&h.state, &project_id, "protected drift", "review").await;
    let project = h
        .agents
        .projects
        .get(&uuid::Uuid::parse_str(&project_id).unwrap())
        .unwrap();
    std::fs::write(
        project.root_path.join("concurrent.txt"),
        "protected change\n",
    )
    .unwrap();
    let git = CommandGit::new("git");
    git.run(&project.root_path, &["add", "--", "concurrent.txt"])
        .unwrap();
    git.run(
        &project.root_path,
        &["commit", "--quiet", "-m", "concurrent protected change"],
    )
    .unwrap();
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
    assert_eq!(body["error"]["code"], "PROTECTED_HEAD_DRIFT");
    assert!(
        !project.root_path.join("drift.txt").exists(),
        "reviewed work must not merge onto a moved protected head"
    );
}
