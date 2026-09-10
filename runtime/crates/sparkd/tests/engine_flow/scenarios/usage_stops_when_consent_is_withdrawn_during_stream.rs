#[tokio::test]
async fn usage_stops_when_consent_is_withdrawn_during_stream() {
    use axum::body::{Body, to_bytes};
    use axum::http::Request;
    use tower::ServiceExt;

    let (h, addr, key, device_id) = harness(240 << 30).await;
    let client = reqwest::Client::new();
    let operation = load_model(&client, addr, &key, &device_id, None).await;
    let operation_id = uuid::Uuid::parse_str(operation["id"].as_str().unwrap()).unwrap();
    assert_eq!(
        wait_terminal(&h.state, operation_id, Duration::from_secs(10)).await["state"],
        "succeeded"
    );
    h.state.telemetry_consent.write().functional = true;
    let body = serde_json::to_vec(&json!({
        "model": "example-32b",
        "messages": [{"role": "user", "content": "consent withdrawal fixture"}],
        "stream": true,
        "stream_options": {"include_usage": true}
    }))
    .unwrap();
    let (headers, body) = signed_parts(&key, &device_id, "POST", "/v1/chat/completions", &body);
    let mut request = Request::builder()
        .method("POST")
        .uri("/v1/chat/completions");
    for (name, value) in headers {
        request = request.header(name, value);
    }
    let response = router(h.state.clone())
        .oneshot(request.body(Body::from(body)).unwrap())
        .await
        .unwrap();
    assert_eq!(response.status(), axum::http::StatusCode::OK);
    assert_eq!(h.engine.inference_active()["active_requests"], 1);
    let before: i64 = h
        .state
        .database
        .as_ref()
        .unwrap()
        .lock()
        .query_row("SELECT COUNT(*) FROM usage_daily", [], |row| row.get(0))
        .unwrap();
    assert_eq!(before, 0, "setup must not contribute usage");
    // Hold the real proxy body until withdrawal so completion accounting cannot win a timing race.
    h.state.telemetry_consent.write().functional = false;
    let bytes = to_bytes(response.into_body(), 1 << 20).await.unwrap();
    assert!(String::from_utf8_lossy(&bytes).contains("[DONE]"));
    assert_eq!(h.engine.inference_active()["active_requests"], 0);
    let conn = h.state.database.as_ref().unwrap().lock();
    let rows: i64 = conn
        .query_row("SELECT COUNT(*) FROM usage_daily", [], |row| row.get(0))
        .unwrap();
    assert_eq!(
        rows, 0,
        "an in-flight stream recorded usage after consent withdrawal"
    );
}
