#[tokio::test]
async fn create_then_validate_walks_to_ready() {
    // The coordinator itself must be a member; it takes the leader role.
    let (state, client, database, _guard) =
        test_state("owner", healthy_report(), CollectiveOutcome::Passed);
    let expected_event_time = state.clock.now_rfc3339();
    let mut live_events = state.events.subscribe();
    let ids = vec![
        state.identity.node_id().to_string(),
        uuid::Uuid::new_v4().to_string(),
    ];
    record_peer_facts(&database, &facts_for(&ids, "auth-1", "0.1.0"));

    let (status, value) = send(
        state.clone(),
        signed_request(
            &client,
            "POST",
            "/api/v1/cluster/create",
            Some(&create_body(&ids)),
        ),
    )
    .await;
    assert_eq!(status, StatusCode::ACCEPTED);
    let operation_id = value["id"].as_str().unwrap().to_owned();
    assert_eq!(wait_for_operation(&database, &operation_id), "succeeded");

    let (status, value) = send(
        state.clone(),
        signed_request(&client, "GET", "/api/v1/cluster", None),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(value["state"], "validating");
    let members = value["members"].as_array().unwrap();
    assert_eq!(members.len(), 2);
    let roles: Vec<&str> = members
        .iter()
        .map(|m| m["role"].as_str().unwrap())
        .collect();
    assert!(roles.contains(&"leader"));
    assert!(roles.contains(&"worker"));

    // Validate (admin) → ready, with events recorded.
    let (status, value) = send(
        state.clone(),
        signed_request(&client, "POST", "/api/v1/cluster/validate", None),
    )
    .await;
    assert_eq!(status, StatusCode::ACCEPTED);
    let operation_id = value["id"].as_str().unwrap().to_owned();
    assert_eq!(wait_for_operation(&database, &operation_id), "succeeded");

    let (_status, value) = send(
        state.clone(),
        signed_request(&client, "GET", "/api/v1/cluster", None),
    )
    .await;
    assert_eq!(value["state"], "ready");

    let events: Vec<String> = {
        let conn = database.lock();
        let mut stmt = conn
            .prepare("SELECT event_type FROM events ORDER BY sequence")
            .unwrap();
        stmt.query_map([], |row| row.get(0))
            .unwrap()
            .collect::<Result<Vec<_>, _>>()
            .unwrap()
    };
    assert!(events.contains(&"cluster.node.joined".to_owned()));
    assert!(events.contains(&"cluster.validation.progress".to_owned()));
    assert!(events.contains(&"cluster.ready".to_owned()));
    let mut live_ready = None;
    while let Ok(event) = live_events.try_recv() {
        if event["type"] == "cluster.ready" {
            live_ready = Some(event);
        }
    }
    let live_ready = live_ready.expect("cluster.ready reaches AppState event subscribers");
    assert_eq!(live_ready["occurred_at"], expected_event_time);
}
