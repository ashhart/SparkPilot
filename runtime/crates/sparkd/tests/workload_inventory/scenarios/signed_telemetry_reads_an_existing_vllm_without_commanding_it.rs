#[tokio::test]
async fn signed_telemetry_reads_an_existing_vllm_without_commanding_it() {
    let listener = tokio::net::TcpListener::bind(("127.0.0.1", 0))
        .await
        .unwrap();
    let port = listener.local_addr().unwrap().port();
    let app = axum::Router::new().route(
        "/metrics",
        axum::routing::get(|| async {
            "vllm:num_requests_running{model_name=\"deepseek-ai/DeepSeek-R1\"} 2\n\
             vllm:num_requests_waiting{model_name=\"deepseek-ai/DeepSeek-R1\"} 1\n\
             vllm:prompt_tokens_total{model_name=\"deepseek-ai/DeepSeek-R1\"} 500000\n\
             vllm:generation_tokens_total{model_name=\"deepseek-ai/DeepSeek-R1\"} 250000\n\
             vllm:request_success_total{model_name=\"deepseek-ai/DeepSeek-R1\"} 1200\n\
             vllm:time_to_first_token_seconds_sum 21\n\
             vllm:time_to_first_token_seconds_count 100\n\
             vllm:e2e_request_latency_seconds_sum 94\n\
             vllm:e2e_request_latency_seconds_count 100\n"
        }),
    );
    let server = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
    let harness = harness("owner", true);
    let mut existing = container(
        "1a3b",
        Some("existing-vllm"),
        Some("vllm/vllm-openai:v0.10"),
    );
    existing.ports.push(ObservedPort {
        host_ip: "0.0.0.0".into(),
        host_port: port,
        container_port: 8000,
        protocol: "tcp".into(),
    });
    *harness.scripted_workloads.lock().unwrap() = Some(ObservedWorkloads {
        containers: vec![existing],
        truncated: false,
        unreadable_lines: 0,
    });

    let (status, body) = send(
        harness.state,
        signed_get(&harness.client, "/api/v1/telemetry"),
    )
    .await;

    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["engines"][0]["engine"], "vllm");
    assert_eq!(body["engines"][0]["ownership"], "external_observed");
    assert_eq!(body["engines"][0]["availability"], "live");
    assert_eq!(
        body["engines"][0]["served_model"],
        "deepseek-ai/DeepSeek-R1"
    );
    assert_eq!(body["engines"][0]["total_requests"], 1200);
    assert_eq!(body["engines"][0]["prompt_tokens"], 500_000);
    assert_eq!(body["engines"][0]["generated_tokens"], 250_000);
    assert_eq!(body["engines"][0]["running_requests"], 2);
    assert_eq!(body["engines"][0]["queue_depth"], 1);
    assert_eq!(body["engines"][0]["time_to_first_token_ms"], 210.0);
    assert_eq!(body["engines"][0]["request_latency_ms"], 940.0);
    assert_eq!(body["inference"]["state"], "ready");
    assert_eq!(
        harness.observed_operations.lock().unwrap().as_slice(),
        ["inventory_workloads"],
        "metrics observation must remain read-only"
    );
    let _: spark_contracts::generated::TelemetrySnapshot =
        serde_json::from_value(body).expect("telemetry response must match the contract");
    server.abort();
}
