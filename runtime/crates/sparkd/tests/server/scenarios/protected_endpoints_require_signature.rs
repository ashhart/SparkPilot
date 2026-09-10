#[tokio::test]
async fn protected_endpoints_require_signature() {
    let (state, _) = test_state();
    // Unsigned request to a protected endpoint must be rejected.
    let request = Request::builder()
        .uri("/api/v1/identity")
        .body(axum::body::Body::empty())
        .unwrap();
    let response = router(state).oneshot(request).await.unwrap();
    assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
}
