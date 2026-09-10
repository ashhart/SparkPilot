#[tokio::test]
async fn health_matches_contract_and_leaks_no_secret() {
    // Health is public-narrow: no signature required.
    let request = Request::builder()
        .uri("/api/v1/health")
        .body(axum::body::Body::empty())
        .unwrap();
    let (state, _) = test_state();
    let response = router(state).oneshot(request).await.unwrap();
    let status = response.status();
    let bytes = to_bytes(response.into_body(), 1 << 20).await.unwrap();
    let body: Value = serde_json::from_slice(&bytes).unwrap();

    assert_eq!(status, StatusCode::OK);
    // §13.3: the health body is exactly these four public fields.
    assert_eq!(body["status"], "ok");
    assert_eq!(body["api_version"], 1);
    assert_eq!(body["runtime_version"], "0.1.0");
    assert_eq!(body["node_id"].as_str().unwrap().len(), 36);
    let raw = serde_json::to_string(&body).unwrap();
    assert!(
        !raw.contains("authority") && !raw.contains("fingerprint") && !raw.contains("seed"),
        "health body leaked identity material: {raw}"
    );
}
