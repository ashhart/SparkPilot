#[tokio::test]
async fn an_approval_digest_must_match_the_exact_reviewed_evidence() {
    let (h, addr, key, device_id) = harness(reviewed_file_plan("digest.txt", "reviewed\n")).await;
    let client = reqwest::Client::new();
    let project_id = create_project(&client, addr, &key, &device_id, &h.state, "digest").await;
    let (_, started) = signed_json(
        &client,
        addr,
        &key,
        &device_id,
        "POST",
        &format!("/api/v1/projects/{project_id}/agents"),
        Some(json!({ "task": "digest binding" })),
    )
    .await;
    wait_ok(&h.state, started["id"].as_str().unwrap()).await;
    let change = wait_change_status(&h.state, &project_id, "digest binding", "review").await;
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
        Some(json!({ "review_digest": "0".repeat(64) })),
    )
    .await;
    assert_eq!(status, reqwest::StatusCode::CONFLICT, "{body}");
    assert_eq!(body["error"]["code"], "REVIEW_DIGEST_STALE");
    let project = h
        .agents
        .projects
        .get(&uuid::Uuid::parse_str(&project_id).unwrap())
        .unwrap();
    assert!(!project.root_path.join("digest.txt").exists());
}
