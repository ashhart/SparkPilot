#[tokio::test]
async fn enable_validates_mode_before_requesting_presence() {
    let (state, client, database, _guard) =
        test_state("owner");
    let (status, value) = send(
        state,
        signed_request_with_options(
            &client,
            "POST",
            "/api/v1/remote/enable",
            Some(&json!({
                "mode": "quick_tunnel",
                "accepted_preview_digest": "0".repeat(64),
            })),
            vec![],
            uuid::Uuid::new_v4(),
            None,
        ),
    )
    .await;
    assert_eq!(status, StatusCode::UNPROCESSABLE_ENTITY);
    assert_eq!(value["error"]["code"], "REMOTE_MODE_INVALID");
    let details: String = database
        .lock()
        .query_row(
            "SELECT details_json FROM audit_records ORDER BY sequence DESC LIMIT 1",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(
        serde_json::from_str::<Value>(&details).unwrap(),
        json!({ "reason_code": "REMOTE_MODE_INVALID" })
    );
}
