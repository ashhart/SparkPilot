#[tokio::test]
async fn status_uses_telemetry_inference_only_without_an_engine_manager() {
    let (mut state, client) = test_state();
    assert!(state.engine.manager.is_none());
    state.telemetry = Arc::new(TelemetryInferenceMonitor);

    let (status, body) = get_json(state, &client, "/api/v1/status").await;

    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["inference"]["state"], "ready");
    assert_eq!(body["inference"]["model_id"], "telemetry/fallback");
    assert_eq!(body["inference"]["profile_id"], "fallback-profile");
    assert_eq!(body["inference"]["context_length"], 4096);
    assert_eq!(body["inference"]["active_requests"], 2);
    assert_eq!(body["inference"]["queue_depth"], 3);
    assert_eq!(body["inference"]["tokens_per_second"], 12.5);
    assert_eq!(body["inference"]["time_to_first_token_ms"], 42.0);
}
