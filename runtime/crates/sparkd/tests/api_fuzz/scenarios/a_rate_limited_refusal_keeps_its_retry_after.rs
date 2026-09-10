/// Preserve the limiter's typed refusal and Retry-After header through error-envelope normalization.
#[tokio::test]
async fn a_rate_limited_refusal_keeps_its_retry_after() {
    // Keep throttling enabled for this rate-limit response test.
    let harness = harness();
    let mut state = harness.state.clone();
    struct FixedMonotonic(std::time::Instant);
    impl sparkd::ratelimit::Monotonic for FixedMonotonic {
        fn now(&self) -> std::time::Instant { self.0 }
    }
    state.rate_limiter = sparkd::ratelimit::RateLimiter::with_monotonic(
        Arc::new(FixedMonotonic(std::time::Instant::now())),
    );
    // Exceed the general class's 240-request burst so the test reaches an actual rate-limit refusal.
    let mut limited = None;
    for _ in 0..400 {
        let response = router(state.clone())
            .oneshot(signed(
                &harness,
                "POST",
                "/api/v1/settings/telemetry",
                br#"{"functional":true,"technical":false}"#,
            ))
            .await
            .unwrap();
        if response.status() == StatusCode::TOO_MANY_REQUESTS {
            limited = Some(response);
            break;
        }
    }
    let response = limited.expect("the limiter never refused a request");
    assert!(
        response.headers().contains_key("retry-after"),
        "a 429 lost its Retry-After"
    );
    let body = to_bytes(response.into_body(), 1 << 20).await.unwrap();
    let envelope: Value = serde_json::from_slice(&body).unwrap();
    assert_eq!(envelope["error"]["code"], "RATE_LIMITED");
}
