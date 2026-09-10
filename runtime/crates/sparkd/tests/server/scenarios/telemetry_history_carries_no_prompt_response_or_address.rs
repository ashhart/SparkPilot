#[tokio::test]
async fn telemetry_history_carries_no_prompt_response_or_address() {
    let (state, client) = test_state();
    let state = state.with_telemetry_consent(sparkd::appliance_api::TelemetryConsentConfig {
        functional: true,
        technical: false,
    });
    let database = state.database.as_ref().expect("database").clone();
    let now = state.clock.now().unix_timestamp();
    {
        let conn = database.lock();
        spark_telemetry::record_sample(
            &conn,
            now,
            &spark_telemetry::TelemetrySample {
                cpu_utilisation: Some(0.5),
                memory_pressure: Some("warning".to_owned()),
                ..Default::default()
            },
        )
        .unwrap();
    }
    let response = router(state.clone())
        .oneshot(signed_get(&client, "/api/v1/telemetry/history"))
        .await
        .unwrap();
    let raw = String::from_utf8(
        to_bytes(response.into_body(), 1 << 20)
            .await
            .unwrap()
            .to_vec(),
    )
    .unwrap();
    for forbidden in [
        "prompt", "response", "message", "content", "token=", "Bearer", "192.168", "/home/",
        "/var/lib", "http://", "https://",
    ] {
        assert!(
            !raw.contains(forbidden),
            "telemetry history carried {forbidden:?}"
        );
    }
    // The vocabulary that is allowed through is exactly the fixed tokens.
    assert!(raw.contains("\"memory_pressure\":\"warning\""));
}
