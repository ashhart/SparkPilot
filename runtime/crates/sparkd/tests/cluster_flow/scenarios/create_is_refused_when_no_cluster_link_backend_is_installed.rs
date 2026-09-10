/// Refuse cluster creation without a link backend rather than publishing unverified membership.
#[tokio::test]
async fn create_is_refused_when_no_cluster_link_backend_is_installed() {
    let (state, client, database, _guard) = test_state_with_backends(
        "owner",
        Arc::new(NoLinkProbe),
        Arc::new(NoCollectiveTest),
        false,
    );
    let ids = vec![
        state.identity.node_id().to_string(),
        uuid::Uuid::new_v4().to_string(),
    ];
    // Satisfy owner, presence, distinct-member and trusted-peer preconditions so only missing link capability causes refusal.
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

    // Nothing durable may be left behind: no operation, no membership.
    let operations: i64 = {
        let conn = database.lock();
        conn.query_row("SELECT COUNT(*) FROM operations", [], |row| row.get(0))
            .unwrap()
    };
    assert_eq!(
        operations, 0,
        "a refused formation must not create an operation"
    );

    let (_, cluster) = send(
        state,
        signed_request(&client, "GET", "/api/v1/cluster", None),
    )
    .await;
    assert_eq!(cluster["state"], "standalone");
    assert!(cluster["members"].as_array().unwrap().is_empty());
}
