#[tokio::test]
async fn telemetry_history_is_signed_and_separates_raw_from_aggregate() {
    let (state, client) = test_state();
    let state = state.with_telemetry_consent(sparkd::appliance_api::TelemetryConsentConfig {
        functional: true,
        technical: false,
    });
    let database = state.database.as_ref().expect("database").clone();
    let now = state.clock.now().unix_timestamp();
    {
        let mut conn = database.lock();
        for step in 0..3 {
            spark_telemetry::record_sample(
                &conn,
                now - step * spark_telemetry::RAW_BUCKET_SECONDS,
                &spark_telemetry::TelemetrySample {
                    cpu_utilisation: Some(0.25),
                    memory_pressure: Some("normal".to_owned()),
                    ..Default::default()
                },
            )
            .unwrap();
        }
        // One reading old enough to have been folded into a minute.
        spark_telemetry::record_sample(
            &conn,
            now - spark_telemetry::DEFAULT_RAW_RETENTION_SECONDS - 600,
            &spark_telemetry::TelemetrySample {
                cpu_utilisation: Some(0.9),
                ..Default::default()
            },
        )
        .unwrap();
        spark_telemetry::compact(
            &mut conn,
            now,
            spark_telemetry::DEFAULT_RAW_RETENTION_SECONDS,
            spark_telemetry::DEFAULT_AGGREGATE_RETENTION_SECONDS,
        )
        .unwrap();
    }

    let unsigned = router(state.clone())
        .oneshot(
            Request::builder()
                .uri("/api/v1/telemetry/history")
                .body(axum::body::Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(
        unsigned.status(),
        StatusCode::UNAUTHORIZED,
        "history is readable without a signature"
    );

    // Request two days so the range includes raw rows and older compacted minutes beyond default raw retention.
    let from = time::OffsetDateTime::from_unix_timestamp(now - 2 * 24 * 60 * 60)
        .unwrap()
        .format(&time::format_description::well_known::Rfc3339)
        .unwrap();
    let response = router(state.clone())
        .oneshot(signed_get(
            &client,
            &format!("/api/v1/telemetry/history?from={from}"),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    let body: Value =
        serde_json::from_slice(&to_bytes(response.into_body(), 1 << 20).await.unwrap()).unwrap();

    assert_eq!(body["recording"], true);
    assert_eq!(body["retention"]["raw_bucket_seconds"], 10);
    assert_eq!(body["retention"]["aggregate_bucket_seconds"], 60);
    let rows = body["rows"].as_array().expect("rows");
    let resolutions: Vec<&str> = rows
        .iter()
        .map(|row| row["resolution"].as_str().unwrap())
        .collect();
    assert!(resolutions.contains(&"raw"), "{resolutions:?}");
    assert!(
        resolutions.contains(&"minute"),
        "the folded reading is missing: {resolutions:?}"
    );
    for row in rows {
        assert!(row["sample_count"].as_i64().unwrap() >= 1);
        assert!(row["observed_at"].is_string());
    }
}
