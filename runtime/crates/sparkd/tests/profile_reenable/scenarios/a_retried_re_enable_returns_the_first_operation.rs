#[tokio::test]
async fn a_retried_re_enable_returns_the_first_operation() {
    let peer = peer("owner");
    disable_profile(&peer);
    let preview = issue_preview(&peer).await;
    let digest = preview["preview_digest"].as_str().unwrap().to_owned();
    let body = serde_json::to_vec(&json!({ "accepted_preview_digest": digest })).unwrap();
    let idempotency_key = uuid::Uuid::new_v4();

    let (first_status, first) = send(
        &peer,
        signed_request(
            &peer,
            &apply_path(MODEL_PATH, PROFILE),
            &body,
            idempotency_key,
            true,
        ),
    )
    .await;
    assert_eq!(first_status, StatusCode::ACCEPTED, "{first}");

    // Replay the accepted reenable without another review or operation against an already-safe profile.
    let (retry_status, retry) = send(
        &peer,
        signed_request(
            &peer,
            &apply_path(MODEL_PATH, PROFILE),
            &body,
            idempotency_key,
            false,
        ),
    )
    .await;
    assert_eq!(retry_status, StatusCode::ACCEPTED, "{retry}");
    assert_eq!(retry["id"], first["id"]);

    await_operation(&peer, first["id"].as_str().unwrap()).await;
    let conn = peer.state.database.as_ref().unwrap().lock();
    let operations: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM operations WHERE kind = 'model.profile.reenable'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(operations, 1);
}
