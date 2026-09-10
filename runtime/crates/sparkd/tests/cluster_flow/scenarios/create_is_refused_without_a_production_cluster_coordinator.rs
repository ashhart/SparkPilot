#[tokio::test]
async fn create_is_refused_without_a_production_cluster_coordinator() {
    let (state, client, database, _guard) = test_state_with_backends(
        "owner",
        Arc::new(ScriptedLink {
            report: healthy_report(),
            fail: false,
        }),
        Arc::new(ScriptedCollective {
            outcome: CollectiveOutcome::Passed,
        }),
        false,
    );
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

    assert_eq!(status, StatusCode::SERVICE_UNAVAILABLE);
    assert_eq!(value["error"]["code"], "CLUSTER_MANAGEMENT_UNAVAILABLE");
    let operations: i64 = database
        .lock()
        .query_row("SELECT COUNT(*) FROM operations", [], |row| row.get(0))
        .unwrap();
    assert_eq!(operations, 0, "refused creation queued an operation");
}
