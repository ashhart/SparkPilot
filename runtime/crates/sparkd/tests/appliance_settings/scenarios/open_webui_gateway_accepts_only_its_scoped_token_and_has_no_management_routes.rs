#[tokio::test]
async fn open_webui_gateway_accepts_only_its_scoped_token_and_has_no_management_routes() {
    let (state, client, _) = test_state("owner");
    let token = "open-webui-scoped-token-that-is-long-enough";
    state
        .database
        .as_ref()
        .unwrap()
        .lock()
        .execute(
            "INSERT INTO optional_services
                (service_id, enabled, gateway_token_sha256, owner_device_id, recipe_revision, updated_at)
             VALUES ('open-webui', 1, ?1, ?2, 'test', '2026-08-29T00:00:00Z')",
            rusqlite::params![sha256_hex(token.as_bytes()), client.device_id.to_string()],
        )
        .unwrap();

    let request = |path: &str, bearer: Option<&str>| {
        let mut builder = Request::builder().method(Method::GET).uri(path);
        if let Some(bearer) = bearer {
            builder = builder.header("authorization", format!("Bearer {bearer}"));
        }
        builder.body(axum::body::Body::empty()).unwrap()
    };
    assert_eq!(
        send_gateway(state.clone(), request("/v1/models", None)).await,
        StatusCode::UNAUTHORIZED
    );
    assert_eq!(
        send_gateway(
            state.clone(),
            request("/v1/models", Some("wrong-token-that-is-also-long-enough"))
        )
        .await,
        StatusCode::UNAUTHORIZED
    );
    assert_eq!(
        send_gateway(state.clone(), request("/v1/models", Some(token))).await,
        StatusCode::INTERNAL_SERVER_ERROR,
        "the valid token passed authentication and reached the deliberately absent test engine"
    );
    assert_eq!(
        send_gateway(state, request("/api/v1/power/shutdown", Some(token))).await,
        StatusCode::NOT_FOUND
    );
}
