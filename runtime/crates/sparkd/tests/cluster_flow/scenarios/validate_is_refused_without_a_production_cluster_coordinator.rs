#[tokio::test]
async fn validate_is_refused_without_a_production_cluster_coordinator() {
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
    let facts = facts_for(&ids, "auth-1", "0.1.0");
    state
        .cluster
        .as_ref()
        .expect("cluster service")
        .create("Seeded cluster", &facts)
        .expect("seed cluster without using the HTTP mutation");

    let (status, value) = send(
        state,
        signed_request(&client, "POST", "/api/v1/cluster/validate", None),
    )
    .await;

    assert_eq!(status, StatusCode::SERVICE_UNAVAILABLE);
    assert_eq!(value["error"]["code"], "CLUSTER_MANAGEMENT_UNAVAILABLE");
    let operations: i64 = database
        .lock()
        .query_row("SELECT COUNT(*) FROM operations", [], |row| row.get(0))
        .unwrap();
    assert_eq!(operations, 0, "refused validation queued an operation");
}
