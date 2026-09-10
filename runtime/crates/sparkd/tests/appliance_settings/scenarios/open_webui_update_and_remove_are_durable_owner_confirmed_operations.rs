#[tokio::test]
async fn open_webui_update_and_remove_are_durable_owner_confirmed_operations() {
    let (state, client, observed) = test_state("owner");
    state
        .database
        .as_ref()
        .unwrap()
        .lock()
        .execute(
            "INSERT INTO optional_services
                (service_id, enabled, gateway_token_sha256, owner_device_id, recipe_revision, updated_at)
             VALUES ('open-webui', 1, ?1, ?2, 'old', '2026-08-29T00:00:00Z')",
            rusqlite::params!["a".repeat(64), client.device_id.to_string()],
        )
        .unwrap();
    for (path, body, expected_kind) in [
        (
            "/api/v1/services/open-webui/update",
            Value::Null,
            "update_open_webui",
        ),
        (
            "/api/v1/services/open-webui/remove",
            json!({ "erase_data": false }),
            "remove_open_webui",
        ),
    ] {
        let (status, operation) = send(
            state.clone(),
            signed_request(&client, Method::POST, path, body, true),
        )
        .await;
        assert_eq!(status, StatusCode::ACCEPTED, "{operation}");
        wait_for(&observed, expected_kind);
    }
}
