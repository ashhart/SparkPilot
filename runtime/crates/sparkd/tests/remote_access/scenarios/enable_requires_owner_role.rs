#[tokio::test]
async fn enable_requires_owner_role() {
    let (state, client, database, _guard) =
        test_state("developer");
    let (status, value) = send(
        state.clone(),
        signed_request_with_options(
            &client,
            "POST",
            "/api/v1/remote/enable",
            Some(&json!({
                "mode": "private_overlay",
                "accepted_preview_digest": "0".repeat(64),
            })),
            vec![],
            uuid::Uuid::new_v4(),
            None,
        ),
    )
    .await;
    assert_eq!(status, StatusCode::FORBIDDEN);
    assert_eq!(value["error"]["code"], "ROLE_FORBIDDEN");
    let audit: (String, String, String) = database
        .lock()
        .query_row(
            "SELECT action, result, details_json FROM audit_records ORDER BY sequence DESC LIMIT 1",
            [],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
        )
        .unwrap();
    assert_eq!(audit.0, "remote.enable");
    assert_eq!(audit.1, "refused");
    assert_eq!(
        serde_json::from_str::<Value>(&audit.2).unwrap(),
        json!({ "reason_code": "ROLE_FORBIDDEN" })
    );
}
