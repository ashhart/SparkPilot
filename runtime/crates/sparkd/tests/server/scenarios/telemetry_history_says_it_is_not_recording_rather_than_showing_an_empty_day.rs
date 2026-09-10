#[tokio::test]
async fn telemetry_history_says_it_is_not_recording_rather_than_showing_an_empty_day() {
    let (state, client) = test_state();
    let state = state.with_telemetry_consent(sparkd::appliance_api::TelemetryConsentConfig {
        functional: false,
        technical: false,
    });
    let response = router(state.clone())
        .oneshot(signed_get(&client, "/api/v1/telemetry/history"))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    let body: Value =
        serde_json::from_slice(&to_bytes(response.into_body(), 1 << 16).await.unwrap()).unwrap();
    assert_eq!(
        body["recording"], false,
        "a Spark that is not recording reported as if it were"
    );
    assert!(body["rows"].as_array().unwrap().is_empty());
    assert!(body["latest_observed_at"].is_null());
}
