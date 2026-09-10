/// P2-1: exactly one of many concurrent identical signed requests is accepted.
#[tokio::test]
async fn one_nonce_admits_exactly_one_concurrent_request() {
    let harness = harness();
    let key = fresh_key();
    let device_id = seed_device(&harness.state, &key, "owner");
    let nonce = fresh_nonce();

    // Send identical signed requests concurrently and require exactly one conditional nonce admission.
    let mut tasks = Vec::new();
    for _ in 0..24 {
        let state = harness.state.clone();
        let key = key.clone();
        let nonce = nonce.clone();
        tasks.push(tokio::spawn(async move {
            let request = signed(
                &key,
                &device_id,
                Method::GET,
                "/api/v1/identity",
                &[],
                &nonce,
            );
            send(&state, request).await.0
        }));
    }
    let mut accepted = 0;
    let mut refused = 0;
    for task in tasks {
        match task.await.unwrap() {
            StatusCode::OK => accepted += 1,
            StatusCode::CONFLICT | StatusCode::TOO_MANY_REQUESTS => refused += 1,
            other => panic!("unexpected status {other}"),
        }
    }
    assert_eq!(accepted, 1, "exactly one request may use a nonce");
    assert_eq!(
        refused, 23,
        "every replay is refused even after its source budget is empty"
    );
}

#[tokio::test]
async fn replay_events_are_bounded_even_when_the_source_address_rotates() {
    struct FixedMonotonic(std::time::Instant);
    impl sparkd::ratelimit::Monotonic for FixedMonotonic {
        fn now(&self) -> std::time::Instant { self.0 }
    }
    let mut harness = harness();
    harness.state.rate_limiter = sparkd::ratelimit::RateLimiter::with_monotonic(Arc::new(FixedMonotonic(std::time::Instant::now())));
    let key = fresh_key();
    let device = seed_device(&harness.state, &key, "owner");
    let request = signed(&key, &device, Method::GET, "/api/v1/identity", &[], &fresh_nonce());
    let headers = request.headers().clone();
    assert_eq!(send(&harness.state, request).await.0, StatusCode::OK);
    let mut limited = 0;
    for index in 1..=64 {
        let mut replay = Request::builder().uri("/api/v1/identity").body(axum::body::Body::empty()).unwrap();
        *replay.headers_mut() = headers.clone();
        replay.extensions_mut().insert(ConnectInfo(format!("198.51.100.{index}:4500").parse::<std::net::SocketAddr>().unwrap()));
        let status = send(&harness.state, replay).await.0;
        assert!(matches!(status, StatusCode::CONFLICT | StatusCode::TOO_MANY_REQUESTS));
        limited += usize::from(status == StatusCode::TOO_MANY_REQUESTS);
    }
    let events: usize = harness.state.database.as_ref().unwrap().lock().query_row(
        "SELECT COUNT(*) FROM events WHERE event_type='security.replay.rejected'", [], |row| row.get(0)).unwrap();
    assert!(limited > 0 && events <= 20, "rotating-source replays wrote {events} events with {limited} throttled");
    let fresh = signed(&key, &device, Method::GET, "/api/v1/identity", &[], &fresh_nonce());
    assert_eq!(send(&harness.state, fresh).await.0, StatusCode::OK);
}
