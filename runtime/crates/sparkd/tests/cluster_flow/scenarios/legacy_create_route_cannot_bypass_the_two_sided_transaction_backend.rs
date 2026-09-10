#[tokio::test]
async fn legacy_create_route_cannot_bypass_the_two_sided_transaction_backend() {
    let (state, client, database, _guard) =
        test_state("owner", healthy_report(), CollectiveOutcome::Passed);
    let coordinator = Arc::new(ClusterCoordinationService::new(
        database.clone(),
        state.identity.clone(),
        Arc::new(TransactionLinkBoundary),
        Arc::new(NoDistributedRuntime),
    ));
    let ids = vec![
        state.identity.node_id().to_string(),
        uuid::Uuid::new_v4().to_string(),
    ];
    record_peer_facts(&database, &facts_for(&ids, "auth-1", "0.1.0"));

    let (status, value) = send(
        state.with_cluster_coordination(coordinator),
        signed_request(
            &client,
            "POST",
            "/api/v1/cluster/create",
            Some(&create_body(&ids)),
        ),
    )
    .await;

    assert_eq!(status, StatusCode::CONFLICT);
    assert_eq!(value["error"]["code"], "CLUSTER_TRANSACTION_REQUIRED");
    let operations: i64 = database
        .lock()
        .query_row("SELECT COUNT(*) FROM operations", [], |row| row.get(0))
        .unwrap();
    assert_eq!(operations, 0);
}
