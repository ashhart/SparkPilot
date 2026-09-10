#[tokio::test]
async fn an_unrelated_same_tree_commit_is_not_mistaken_for_a_merge_retry() {
    let (h, addr, key, device_id) =
        harness(reviewed_file_plan("same-tree.txt", "reviewed\n")).await;
    let client = reqwest::Client::new();
    let project_id = create_project(&client, addr, &key, &device_id, &h.state, "same-tree").await;
    let (_, started) = signed_json(
        &client,
        addr,
        &key,
        &device_id,
        "POST",
        &format!("/api/v1/projects/{project_id}/agents"),
        Some(json!({ "task": "same tree protected drift" })),
    )
    .await;
    wait_ok(&h.state, started["id"].as_str().unwrap()).await;
    let change =
        wait_change_status(&h.state, &project_id, "same tree protected drift", "review").await;
    let project = h
        .agents
        .projects
        .get(&uuid::Uuid::parse_str(&project_id).unwrap())
        .unwrap();
    std::fs::write(project.root_path.join("same-tree.txt"), "reviewed\n").unwrap();
    let git = CommandGit::new("git");
    git.run(&project.root_path, &["add", "--", "same-tree.txt"])
        .unwrap();
    git.run(
        &project.root_path,
        &[
            "commit",
            "--quiet",
            "-m",
            "unrelated commit with reviewed tree",
        ],
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
}
