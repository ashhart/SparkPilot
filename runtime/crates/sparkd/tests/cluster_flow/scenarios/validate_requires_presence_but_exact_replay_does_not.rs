#[tokio::test]
async fn validate_requires_presence_but_exact_replay_does_not() {
    let (state, client, database, _guard) =
        test_state("owner", healthy_report(), CollectiveOutcome::Passed);
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

    let idempotency_key = uuid::Uuid::new_v4();
    let path = "/api/v1/cluster/validate";
    let (status, value) = send(
        state.clone(),
        signed_request_with_options(&client, "POST", path, None, idempotency_key, None),
    )
    .await;
    assert_eq!(status, StatusCode::FORBIDDEN);
    assert_eq!(value["error"]["code"], "USER_PRESENCE_REQUIRED");

    let (first_status, first) = send(
        state.clone(),
        signed_request_with_options(&client, "POST", path, None, idempotency_key, Some(path)),
    )
    .await;
    assert_eq!(first_status, StatusCode::ACCEPTED);
    let operation_id = first["id"].as_str().unwrap().to_owned();
    assert_eq!(wait_for_operation(&database, &operation_id), "succeeded");

    let (replay_status, replay) = send(
        state,
        signed_request_with_options(&client, "POST", path, None, idempotency_key, None),
    )
    .await;
    assert_eq!(replay_status, StatusCode::ACCEPTED);
    assert_eq!(replay, first);

    let audit: Vec<(String, Option<String>, Option<String>, String)> = {
        let connection = database.lock();
        let mut statement = connection
            .prepare(
                "SELECT result, resource, operation_id, details_json
                   FROM audit_records
                  WHERE action = 'cluster.validate'
                  ORDER BY sequence",
            )
            .unwrap();
        statement
            .query_map([], |row| {
                Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?))
            })
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap()
    };
    assert_eq!(audit.len(), 3);
    assert_eq!(audit[0].0, "refused");
    assert_eq!(audit[0].1.as_deref(), Some("cluster"));
    assert_eq!(audit[0].2, None);
    assert_eq!(
        serde_json::from_str::<Value>(&audit[0].3).unwrap(),
        json!({ "reason_code": "USER_PRESENCE_REQUIRED" })
    );
    assert_eq!(audit[1].0, "accepted");
    assert_eq!(audit[1].1.as_deref(), Some("cluster"));
    assert_eq!(audit[1].2.as_deref(), Some(operation_id.as_str()));
    assert_eq!(
        serde_json::from_str::<Value>(&audit[1].3).unwrap(),
        json!({})
    );
    assert_eq!(audit[2].0, "succeeded");
    assert_eq!(audit[2].2.as_deref(), Some(operation_id.as_str()));
}
