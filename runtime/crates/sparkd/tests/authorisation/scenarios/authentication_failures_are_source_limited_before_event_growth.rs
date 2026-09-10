/// Limit signature failures by source before device throttling and stop durable event growth when that budget is exhausted.
#[tokio::test]
async fn authentication_failures_are_source_limited_before_event_growth() {
    let harness = harness();
    let source: std::net::SocketAddr = "192.0.2.10:41000".parse().unwrap();
    let mut last_status = StatusCode::OK;
    for _ in 0..30 {
        let mut request = Request::builder()
            .method(Method::GET)
            .uri("/api/v1/identity")
            .body(axum::body::Body::empty())
            .unwrap();
        request.extensions_mut().insert(ConnectInfo(source));
        (last_status, _) = send(&harness.state, request).await;
    }
    assert_eq!(last_status, StatusCode::TOO_MANY_REQUESTS);

    let events: i64 = harness
        .state
        .database
        .as_ref()
        .unwrap()
        .lock()
        .query_row(
            "SELECT COUNT(*) FROM events WHERE event_type = 'security.signature.rejected'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(
        events, 20,
        "the source burst bounds durable rejection events"
    );

    let mut other = Request::builder()
        .method(Method::GET)
        .uri("/api/v1/identity")
        .body(axum::body::Body::empty())
        .unwrap();
    other.extensions_mut().insert(ConnectInfo(
        "198.51.100.20:42000"
            .parse::<std::net::SocketAddr>()
            .unwrap(),
    ));
    let (status, _) = send(&harness.state, other).await;
    assert_eq!(status, StatusCode::UNAUTHORIZED, "budgets are per source");
}
