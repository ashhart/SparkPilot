#[tokio::test]
async fn project_lifecycle_list_and_get() {
    let (h, addr, key, device_id) = harness().await;
    let client = reqwest::Client::new();

    let operation_id = create_through_api(&client, addr, &key, &device_id, "hello-world").await;
    let state = wait_op(&h.state, operation_id, Duration::from_secs(20)).await;
    assert_eq!(state, "succeeded");

    let (status, list) = signed_json(
        &client,
        addr,
        &key,
        &device_id,
        "GET",
        "/api/v1/projects",
        None,
    )
    .await;
    assert_eq!(status, reqwest::StatusCode::OK, "{list}");
    let items = list["items"].as_array().expect("items array");
    assert_eq!(items.len(), 1, "{list}");
    assert_eq!(list["capabilities"], json!(["create"]), "{list}");
    assert_eq!(
        items[0]["capabilities"],
        json!(["read", "write", "terminal", "preview", "review", "delete"]),
        "the owner journey must be projected from the effective role and project grant: {list}"
    );
    assert!(
        items[0].get("root_path").is_none(),
        "internal paths must not be serialised: {list}"
    );
    let project_id = items[0]["id"].as_str().expect("project id").to_owned();
    assert_eq!(items[0]["state"], "ready");

    // Do not advertise scripted empty planners or create fake successful agent operations.
    let agent_path = format!("/api/v1/projects/{project_id}/agents");
    let (status, refusal) = signed_json(
        &client,
        addr,
        &key,
        &device_id,
        "POST",
        &agent_path,
        Some(json!({ "task": "Change the greeting" })),
    )
    .await;
    assert_eq!(
        status,
        reqwest::StatusCode::SERVICE_UNAVAILABLE,
        "{refusal}"
    );
    assert_eq!(
        refusal["error"]["code"], "AGENT_EXECUTION_UNAVAILABLE",
        "{refusal}"
    );
    let fake_operations: i64 = h
        .state
        .database
        .as_ref()
        .unwrap()
        .lock()
        .query_row(
            "SELECT COUNT(*) FROM operations WHERE kind='project.agent'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(fake_operations, 0);
    // The git checkout exists on disk.
    let view = h
        .projects
        .get(&uuid::Uuid::parse_str(&project_id).unwrap())
        .unwrap();
    assert!(view.root_path.exists(), "project root on disk");

    let (status, detail) = signed_json(
        &client,
        addr,
        &key,
        &device_id,
        "GET",
        &format!("/api/v1/projects/{project_id}"),
        None,
    )
    .await;
    assert_eq!(status, reqwest::StatusCode::OK, "{detail}");
    assert_eq!(detail["name"], "hello-world");
    assert_eq!(detail["state"], "ready");
    assert_eq!(detail["capabilities"], items[0]["capabilities"]);
    assert!(
        detail.get("root_path").is_none(),
        "internal paths must not be serialised: {detail}"
    );
}
