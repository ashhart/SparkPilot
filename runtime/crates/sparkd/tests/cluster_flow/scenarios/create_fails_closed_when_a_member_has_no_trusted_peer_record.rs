#[tokio::test]
async fn create_fails_closed_when_a_member_has_no_trusted_peer_record() {
    let (state, client, database, _guard) =
        test_state("owner", healthy_report(), CollectiveOutcome::Passed);
    let ids = vec![
        state.identity.node_id().to_string(),
        uuid::Uuid::new_v4().to_string(),
    ];
    record_peer_facts(&database, &facts_for(&ids[..1], "auth-1", "0.1.0"));

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
    let operation_id = value["id"].as_str().unwrap();
    assert_eq!(wait_for_operation(&database, operation_id), "failed");

    let (_, cluster) = send(
        state,
        signed_request(&client, "GET", "/api/v1/cluster", None),
    )
    .await;
    assert_eq!(cluster["state"], "standalone");
}
