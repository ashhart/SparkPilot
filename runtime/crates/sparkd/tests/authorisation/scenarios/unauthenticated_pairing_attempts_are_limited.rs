/// Limit unpaired callers by source so rotating device-id headers cannot select another budget.
#[tokio::test]
async fn unauthenticated_pairing_attempts_are_limited() {
    let harness = harness();
    let source: std::net::SocketAddr = "192.0.2.30:43000".parse().unwrap();
    let mut limited = false;
    for _ in 0..40 {
        let mut request = Request::builder()
            .method(Method::POST)
            .uri("/api/v1/pairing/challenge")
            .header("content-type", "application/json")
            .body(axum::body::Body::from(json!({}).to_string()))
            .unwrap();
        request.extensions_mut().insert(ConnectInfo(source));
        let (status, _) = send(&harness.state, request).await;
        if status == StatusCode::TOO_MANY_REQUESTS {
            limited = true;
            break;
        }
    }
    assert!(limited, "pairing attempts must be bounded");

    let mut other = Request::builder()
        .method(Method::POST)
        .uri("/api/v1/pairing/challenge")
        .header("content-type", "application/json")
        .body(axum::body::Body::from(json!({}).to_string()))
        .unwrap();
    other.extensions_mut().insert(ConnectInfo(
        "198.51.100.40:44000"
            .parse::<std::net::SocketAddr>()
            .unwrap(),
    ));
    let (status, _) = send(&harness.state, other).await;
    assert_ne!(
        status,
        StatusCode::TOO_MANY_REQUESTS,
        "one peer must not spend another peer's pairing budget"
    );
}
