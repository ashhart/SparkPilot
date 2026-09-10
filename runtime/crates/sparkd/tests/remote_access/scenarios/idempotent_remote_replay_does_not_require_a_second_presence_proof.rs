#[tokio::test]
async fn idempotent_remote_replay_does_not_require_a_second_presence_proof() {
    let (state, client, database, _guard) =
        test_state("owner");
    let idempotency_key = uuid::Uuid::new_v4();
    let body = preview_enable_body(&state, &client, "private_overlay", None).await;
    let (first_status, first) = send(
        state.clone(),
        signed_request_with_options(
            &client,
            "POST",
            "/api/v1/remote/enable",
            Some(&body),
            vec![],
            idempotency_key,
            Some("/api/v1/remote/enable"),
        ),
    )
    .await;
    assert_eq!(first_status, StatusCode::ACCEPTED);

    let (replay_status, replay) = send(
        state,
        signed_request_with_options(
            &client,
            "POST",
            "/api/v1/remote/enable",
            Some(&body),
            vec![],
            idempotency_key,
            None,
        ),
    )
    .await;
    assert_eq!(replay_status, StatusCode::ACCEPTED);
    assert_eq!(replay, first);

    let accepted_count: i64 = database
        .lock()
        .query_row(
            "SELECT COUNT(*) FROM audit_records WHERE action = 'remote.enable' AND result = 'accepted'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(accepted_count, 1);
    let refused_count: i64 = database
        .lock()
        .query_row(
            "SELECT COUNT(*) FROM audit_records WHERE action = 'remote.enable' AND result = 'refused'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(refused_count, 0);
}
