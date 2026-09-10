#[tokio::test]
async fn usage_is_recorded_from_completions() {
    let clock = Arc::new(ManualUtcClock::new(
        time::OffsetDateTime::parse(
            "2024-01-02T00:30:00+01:00",
            &time::format_description::well_known::Rfc3339,
        )
        .unwrap(),
    ));
    let (h, addr, key, device_id) = harness_with_clock(240 << 30, clock).await;
    let client = reqwest::Client::new();

    let operation_id: uuid::Uuid = load_model(&client, addr, &key, &device_id, None).await["id"]
        .as_str()
        .and_then(|s| uuid::Uuid::parse_str(s).ok())
        .expect("load operation id");
    wait_terminal(&h.state, operation_id, Duration::from_secs(10)).await;

    // Do not create local usage rows before functional-telemetry consent.
    let (status, _) = signed_json(
        &client,
        addr,
        &key,
        &device_id,
        "POST",
        "/v1/chat/completions",
        Some(json!({
            "model": "example-32b",
            "messages": [{"role": "user", "content": "not retained"}],
            "max_tokens": 8,
            "stream": false,
        })),
    )
    .await;
    assert_eq!(status, reqwest::StatusCode::OK);
    assert!(
        spark_telemetry::daily_summary(
            &h.state.database.as_ref().expect("db").lock(),
            "2024-01-01"
        )
        .expect("daily summary before consent")
        .is_empty()
    );

    *h.state.telemetry_consent.write() = TelemetryConsentConfig {
        functional: true,
        technical: false,
    };

    // One non-stream and one streamed completion through the proxy.
    let (status, _) = signed_json(
        &client,
        addr,
        &key,
        &device_id,
        "POST",
        "/v1/chat/completions",
        Some(json!({
            "model": "example-32b",
            "messages": [{"role": "user", "content": "hi"}],
            "max_tokens": 8,
            "stream": false,
        })),
    )
    .await;
    assert_eq!(status, reqwest::StatusCode::OK);

    let (headers, bytes) = signed_parts(
        &key,
        &device_id,
        "POST",
        "/v1/chat/completions",
        &serde_json::to_vec(&json!({
            "model": "example-32b",
            "messages": [{"role": "user", "content": "stream too"}],
            "stream": true,
            "stream_options": {"include_usage": true},
        }))
        .unwrap(),
    );
    let mut builder = client
        .post(format!("http://{addr}/v1/chat/completions"))
        .body(bytes);
    for (name, value) in headers {
        builder = builder.header(name, value);
    }
    let text = builder
        .send()
        .await
        .expect("stream")
        .text()
        .await
        .expect("text");
    assert!(text.contains("[DONE]"), "{text}");

    // Use UTC calendar day even when the injected instant is the next day in its local offset.
    let conn = h.state.database.as_ref().expect("db").lock();
    let summary = spark_telemetry::daily_summary(&conn, "2024-01-01").expect("daily summary");
    let row = summary
        .iter()
        .find(|r| r.model_id == "example/model-32b")
        .expect("usage row for catalogue model");
    assert_eq!(row.requests, 2, "{summary:?}");
    assert!(row.prompt_tokens > 0);
    assert!(row.generated_tokens > 0);
    assert_eq!(row.device_id, device_id.to_string(), "{summary:?}");
    assert!(
        spark_telemetry::daily_summary(&conn, "2024-01-02")
            .expect("local-offset day query")
            .is_empty()
    );
}
