#[tokio::test]
async fn link_failure_fails_validation_and_collective_skip_degrades() {
    // Dead link → failed state + link.changed event, operation failed.
    let dead_link = LinkReport {
        interface: "cx5-0".into(),
        link_up: false,
        mtu: 1500,
        bandwidth_gbitps_ok: false,
    };
    let (state, client, database, _guard) =
        test_state("owner", dead_link, CollectiveOutcome::Passed);
    let ids = vec![
        state.identity.node_id().to_string(),
        uuid::Uuid::new_v4().to_string(),
    ];
    record_peer_facts(&database, &facts_for(&ids, "auth-1", "0.1.0"));
    let (status, created) = send(
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
    assert_eq!(
        wait_for_operation(&database, created["id"].as_str().unwrap()),
        "succeeded"
    );
    let (_, value) = send(
        state.clone(),
        signed_request(&client, "POST", "/api/v1/cluster/validate", None),
    )
    .await;
    let operation_id = value["id"].as_str().unwrap().to_owned();
    assert_eq!(wait_for_operation(&database, &operation_id), "failed");
    let (_, value) = send(
        state,
        signed_request(&client, "GET", "/api/v1/cluster", None),
    )
    .await;
    assert_eq!(value["state"], "failed");

    // Skipped collective (this build's no-backend case) → degraded.
    let (state, client, database, _guard) =
        test_state("owner", healthy_report(), CollectiveOutcome::Skipped);
    let ids = vec![
        state.identity.node_id().to_string(),
        uuid::Uuid::new_v4().to_string(),
    ];
    record_peer_facts(&database, &facts_for(&ids, "auth-1", "0.1.0"));
    let (status, created) = send(
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
    assert_eq!(
        wait_for_operation(&database, created["id"].as_str().unwrap()),
        "succeeded"
    );
    let (_, value) = send(
        state.clone(),
        signed_request(&client, "POST", "/api/v1/cluster/validate", None),
    )
    .await;
    let operation_id = value["id"].as_str().unwrap().to_owned();
    assert_eq!(wait_for_operation(&database, &operation_id), "succeeded");
    let (_, value) = send(
        state,
        signed_request(&client, "GET", "/api/v1/cluster", None),
    )
    .await;
    assert_eq!(value["state"], "degraded");
}
