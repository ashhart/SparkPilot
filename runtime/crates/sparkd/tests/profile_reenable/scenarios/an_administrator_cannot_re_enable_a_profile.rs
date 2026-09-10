#[tokio::test]
async fn an_administrator_cannot_re_enable_a_profile() {
    let peer = peer("administrator");
    disable_profile(&peer);

    let (status, refusal) = send(
        &peer,
        signed_request(
            &peer,
            &preview_path(MODEL_PATH, PROFILE),
            b"",
            uuid::Uuid::new_v4(),
            false,
        ),
    )
    .await;
    assert_eq!(status, StatusCode::FORBIDDEN, "{refusal}");
    assert_eq!(refusal["error"]["code"], "ROLE_FORBIDDEN");

    let conn = peer.state.database.as_ref().unwrap().lock();
    let refusals: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM audit_records WHERE action = 'model.profile.reenable.preview'
             AND result = 'refused'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(refusals, 1, "the refusal is not in the audit chain");
}
