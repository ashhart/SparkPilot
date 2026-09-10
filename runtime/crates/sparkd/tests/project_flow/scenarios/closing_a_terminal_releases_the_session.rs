/// Close owned sessions and release privileged children using the same project/terminal identity.
#[tokio::test]
async fn closing_a_terminal_releases_the_session() {
    let (h, addr, key, device_id) = harness().await;
    let client = reqwest::Client::new();
    let operation_id = create_through_api(&client, addr, &key, &device_id, "closing").await;
    assert_eq!(
        wait_op(&h.state, operation_id, Duration::from_secs(20)).await,
        "succeeded"
    );
    let view = h.projects.list().unwrap().remove(0);
    write_devcontainer(&view.root_path);

    let (status, created) = signed_json(
        &client,
        addr,
        &key,
        &device_id,
        "POST",
        &format!("/api/v1/projects/{}/terminals", view.id),
        Some(json!({ "shell": "bash" })),
    )
    .await;
    assert_eq!(status, reqwest::StatusCode::ACCEPTED, "{created}");
    let terminal_id = created["terminal_id"].as_str().unwrap().to_owned();
    let terminal_uuid = uuid::Uuid::parse_str(&terminal_id).unwrap();

    let (status, body) = signed_json(
        &client,
        addr,
        &key,
        &device_id,
        "DELETE",
        &format!("/api/v1/projects/{}/terminals/{terminal_id}", view.id),
        None,
    )
    .await;
    assert_eq!(status, reqwest::StatusCode::OK, "{body}");
    assert_eq!(body["state"], "closed");
    assert!(h.projects.terminals_for_project(&view.id).is_empty());
    assert_eq!(h.pty.closed(), vec![terminal_uuid]);

    // The durable record agrees.
    let state: String = h
        .state
        .database
        .as_ref()
        .unwrap()
        .lock()
        .query_row(
            "SELECT state FROM project_terminals WHERE id = ?1",
            [terminal_id.clone()],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(state, "closed");

    // A second close finds nothing.
    let (status, _) = signed_json(
        &client,
        addr,
        &key,
        &device_id,
        "DELETE",
        &format!("/api/v1/projects/{}/terminals/{terminal_id}", view.id),
        None,
    )
    .await;
    assert_eq!(status, reqwest::StatusCode::NOT_FOUND);
}
