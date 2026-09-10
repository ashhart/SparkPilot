#[tokio::test]
async fn error_envelope_request_id_matches_the_response_header() {
    // Require envelope request_id to equal the response header and trace correlation id (CODE-1).
    let (state, _) = test_state();
    let request = Request::builder()
        .uri("/api/v1/identity")
        .body(axum::body::Body::empty())
        .unwrap();
    let response = router(state).oneshot(request).await.unwrap();
    assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
    let header_id = response
        .headers()
        .get("x-request-id")
        .expect("x-request-id present on every response")
        .to_str()
        .unwrap()
        .to_owned();
    let body = response_json(response).await;
    assert_eq!(body["error"]["request_id"], serde_json::json!(header_id));
}
