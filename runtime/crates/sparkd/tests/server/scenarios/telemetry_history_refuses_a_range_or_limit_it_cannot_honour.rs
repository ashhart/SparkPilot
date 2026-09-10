#[tokio::test]
async fn telemetry_history_refuses_a_range_or_limit_it_cannot_honour() {
    let (state, client) = test_state();
    for query in [
        "?from=not-a-timestamp",
        "?from=2026-09-01T10:00:00Z&to=2026-09-01T09:00:00Z",
        "?limit=0",
        "?limit=99999",
    ] {
        let response = router(state.clone())
            .oneshot(signed_get(
                &client,
                &format!("/api/v1/telemetry/history{query}"),
            ))
            .await
            .unwrap();
        assert_eq!(
            response.status(),
            StatusCode::BAD_REQUEST,
            "{query} was accepted"
        );
        let body: Value =
            serde_json::from_slice(&to_bytes(response.into_body(), 1 << 16).await.unwrap())
                .unwrap();
        assert_eq!(body["error"]["code"], "INVALID_TIME_RANGE");
    }
}
