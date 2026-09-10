#[tokio::test]
async fn open_webui_access_proxy_fails_closed_until_the_service_is_enabled() {
    let (state, _, _) = test_state("owner");
    let response = sparkd::service_api::access_proxy_router(state)
        .oneshot(
            Request::builder()
                .uri("/")
                .body(axum::body::Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::SERVICE_UNAVAILABLE);
}

#[tokio::test]
async fn open_webui_proxy_uses_only_the_verified_custom_port() {
    let (state, client, _) = test_state("owner");
    state.database.as_ref().unwrap().lock().execute(
        "INSERT INTO optional_services (service_id,enabled,pending_install,gateway_token_sha256,owner_device_id,recipe_revision,updated_at) VALUES ('open-webui',1,0,?1,?2,'test','test')", rusqlite::params!["a".repeat(64), client.device_id.to_string()],
    ).unwrap();
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let server = tokio::spawn(async move {
        axum::serve(listener, axum::Router::new().route("/api/version", axum::routing::get(|| async { "existing-webui-on-custom-port" }))).await.unwrap();
    });
    let request = || Request::builder().uri("/api/version").body(axum::body::Body::empty()).unwrap();
    let app = sparkd::service_api::access_proxy_router(state.clone());
    assert_eq!(app.clone().oneshot(request()).await.unwrap().status(), StatusCode::SERVICE_UNAVAILABLE);
    state.open_webui_upstream_port.store(port, std::sync::atomic::Ordering::SeqCst);
    let response = app.oneshot(request()).await.unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    assert_eq!(to_bytes(response.into_body(), 1024).await.unwrap().as_ref(), b"existing-webui-on-custom-port");
    server.abort();
}
