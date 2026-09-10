#[tokio::test]
async fn an_agent_without_a_project_container_fails_instead_of_using_the_host() {
    let (h, addr, key, device_id) = harness(reviewed_file_plan("host.txt", "must not run\n")).await;
    let client = reqwest::Client::new();
    let (status, created) = signed_json(
        &client,
        addr,
        &key,
        &device_id,
        "POST",
        "/api/v1/projects",
        Some(json!({ "name": "no-container" })),
    )
    .await;
    assert_eq!(status, reqwest::StatusCode::ACCEPTED, "{created}");
    wait_ok(&h.state, created["id"].as_str().unwrap()).await;
    let project_id = {
        let conn = h.state.database.as_ref().unwrap().lock();
        sparkd::store::project_rows(&conn, 10).unwrap()[0]
            .id
            .to_string()
    };
    let (_, started) = signed_json(
        &client,
        addr,
        &key,
        &device_id,
        "POST",
        &format!("/api/v1/projects/{project_id}/agents"),
        Some(json!({ "task": "never use host tools" })),
    )
    .await;
    wait_until_failed(&h.state, started["id"].as_str().unwrap()).await;
    let change = wait_change_status(&h.state, &project_id, "never use host tools", "failed").await;
    let project = h
        .agents
        .projects
        .get(&uuid::Uuid::parse_str(&project_id).unwrap())
        .unwrap();
    assert!(!project.root_path.join("host.txt").exists());
    assert_eq!(
        h.agents
            .change_calls(&uuid::Uuid::parse_str(change["id"].as_str().unwrap()).unwrap())
            .unwrap()
            .len(),
        0
    );
}
