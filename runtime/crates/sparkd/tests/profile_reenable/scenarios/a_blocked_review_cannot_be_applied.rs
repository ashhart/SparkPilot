/// Refuse applying a blocked already-safe-profile preview even when issuance succeeds for explanation.
#[tokio::test]
async fn a_blocked_review_cannot_be_applied() {
    let peer = peer("owner");
    let preview = issue_preview(&peer).await;
    let digest = preview["preview_digest"].as_str().unwrap().to_owned();
    let body = serde_json::to_vec(&json!({ "accepted_preview_digest": digest })).unwrap();

    let (status, refusal) = send(
        &peer,
        signed_request(
            &peer,
            &apply_path(MODEL_PATH, PROFILE),
            &body,
            uuid::Uuid::new_v4(),
            true,
        ),
    )
    .await;
    assert!(
        status.is_client_error(),
        "a blocked review applied: {refusal}"
    );
    assert_eq!(refusal["error"]["code"], "MODEL_PROFILE_ALREADY_SAFE");

    let conn = peer.state.database.as_ref().unwrap().lock();
    let operations: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM operations WHERE kind = 'model.profile.reenable'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(operations, 0, "a blocked review enqueued work");
}
