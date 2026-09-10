#[tokio::test]
async fn external_import_preview_is_authenticated_read_only_and_supports_four_members() {
    let (state, client, database, _guard) =
        test_state("owner", healthy_report(), CollectiveOutcome::Passed);
    let ids = vec![
        state.identity.node_id().to_string(),
        uuid::Uuid::new_v4().to_string(),
        uuid::Uuid::new_v4().to_string(),
        uuid::Uuid::new_v4().to_string(),
    ];
    record_peer_facts(&database, &facts_for(&ids, "independently-paired", "0.1.0"));
    record_reciprocal_fabric_proof(&database, &ids[0], "port-0", &ids[1], "port-1");
    record_reciprocal_fabric_proof(&database, &ids[1], "port-2", &ids[2], "port-3");
    record_reciprocal_fabric_proof(&database, &ids[2], "port-4", &ids[3], "port-5");

    let body = json!({ "name": "Existing lab", "member_node_ids": ids });
    let (status, value) = send(
        state,
        signed_request(
            &client,
            "POST",
            "/api/v1/cluster/import/preview",
            Some(&body),
        ),
    )
    .await;

    assert_eq!(status, StatusCode::OK);
    assert_eq!(value["configuration_owner"], "externally_configured");
    assert_eq!(value["members"].as_array().unwrap().len(), 4);
    assert_eq!(value["authenticated_links"].as_array().unwrap().len(), 3);
    assert!(
        value["authenticated_links"]
            .as_array()
            .unwrap()
            .iter()
            .all(|link| {
                link["path_topology"] == "unknown" && link["direct_connection_proven"] == false
            })
    );
    assert_eq!(value["evidence_complete"], true);
    assert_eq!(value["registration_available"], false);
    assert_eq!(value["automatic_topology_available"], false);
    assert_eq!(value["takeover_available"], false);
    assert_eq!(
        value["preservation_guarantees"],
        json!([
            "netplan",
            "ssh",
            "ray",
            "vllm",
            "models",
            "containers",
            "services"
        ])
    );
    let conn = database.lock();
    let operations: i64 = conn
        .query_row("SELECT COUNT(*) FROM operations", [], |row| row.get(0))
        .unwrap();
    let clusters: i64 = conn
        .query_row("SELECT COUNT(*) FROM cluster_state", [], |row| row.get(0))
        .unwrap();
    assert_eq!(operations, 0, "preview must not create an operation");
    assert_eq!(clusters, 0, "preview must not create cluster identity");
}
