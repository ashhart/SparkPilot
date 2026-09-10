#[tokio::test]
async fn create_requires_owner_and_two_members() {
    let ids = vec![
        uuid::Uuid::new_v4().to_string(),
        uuid::Uuid::new_v4().to_string(),
    ];

    // Developer cannot create.
    let (state, client, developer_database, _guard) =
        test_state("developer", healthy_report(), CollectiveOutcome::Passed);
    let (status, value) = send(
        state,
        signed_request_with_options(
            &client,
            "POST",
            "/api/v1/cluster/create",
            Some(&create_body(&ids)),
            uuid::Uuid::new_v4(),
            None,
        ),
    )
    .await;
    assert_eq!(status, StatusCode::FORBIDDEN);
    assert_eq!(value["error"]["code"], "ROLE_FORBIDDEN");
    let developer_audit: (String, String) = developer_database
        .lock()
        .query_row(
            "SELECT result, details_json FROM audit_records ORDER BY sequence DESC LIMIT 1",
            [],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .unwrap();
    assert_eq!(developer_audit.0, "refused");
    assert_eq!(
        serde_json::from_str::<Value>(&developer_audit.1).unwrap(),
        json!({ "reason_code": "ROLE_FORBIDDEN" })
    );

    // One member is rejected synchronously.
    let (state, client, database, _guard) =
        test_state("owner", healthy_report(), CollectiveOutcome::Passed);
    let (status, value) = send(
        state.clone(),
        signed_request_with_options(
            &client,
            "POST",
            "/api/v1/cluster/create",
            Some(&create_body(&ids[..1])),
            uuid::Uuid::new_v4(),
            None,
        ),
    )
    .await;
    assert_eq!(status, StatusCode::UNPROCESSABLE_ENTITY);
    assert_eq!(value["error"]["code"], "MEMBERSHIP_TOO_SMALL");
    let validation_audit: (String, String) = database
        .lock()
        .query_row(
            "SELECT result, details_json FROM audit_records ORDER BY sequence DESC LIMIT 1",
            [],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .unwrap();
    assert_eq!(validation_audit.0, "refused");
    assert_eq!(
        serde_json::from_str::<Value>(&validation_audit.1).unwrap(),
        json!({ "reason_code": "MEMBERSHIP_TOO_SMALL" })
    );

    let duplicate_id = state.identity.node_id().to_string();
    let duplicate_ids = vec![duplicate_id.clone(), duplicate_id];
    let (status, value) = send(
        state.clone(),
        signed_request(
            &client,
            "POST",
            "/api/v1/cluster/create",
            Some(&create_body(&duplicate_ids)),
        ),
    )
    .await;
    assert_eq!(status, StatusCode::UNPROCESSABLE_ENTITY);
    assert_eq!(value["error"]["code"], "MEMBERSHIP_DUPLICATE");
    let cluster_rows: i64 = database
        .lock()
        .query_row("SELECT COUNT(*) FROM cluster_state", [], |row| row.get(0))
        .unwrap();
    assert_eq!(
        cluster_rows, 0,
        "invalid membership must not leave partial state"
    );

    // Authority mismatch fails the operation.
    let mixed_facts = vec![
        cluster::MemberFacts {
            node_id: ids[0].clone(),
            name: "A".into(),
            authority_fingerprint: "auth-1".into(),
            runtime_version: "0.1.0".into(),
            engine_image: "vllm:0.11".into(),
        },
        cluster::MemberFacts {
            node_id: ids[1].clone(),
            name: "B".into(),
            authority_fingerprint: "auth-2".into(),
            runtime_version: "0.1.0".into(),
            engine_image: "vllm:0.11".into(),
        },
    ];
    record_peer_facts(&database, &mixed_facts);
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
    assert_eq!(wait_for_operation(&database, &operation_id), "failed");
}
