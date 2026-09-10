#[tokio::test]
async fn fixed_target_history_cancel_closes_the_exact_live_proxy_and_replays_receipt() {
    use futures::StreamExt;
    let (h, addr, key, device_id) = harness(240 << 30).await;
    h.state.telemetry_consent.write().functional = true;
    h.backend.set_stall_after_first(true);
    let client = reqwest::Client::new();
    let operation_id = uuid::Uuid::parse_str(
        load_model(&client, addr, &key, &device_id, None).await["id"]
            .as_str()
            .unwrap(),
    )
    .unwrap();
    wait_terminal(&h.state, operation_id, Duration::from_secs(10)).await;
    let body=serde_json::to_vec(&json!({"model":"example/model-32b","messages":[{"role":"user","content":"private stalled request"}],"stream":true})).unwrap();
    let (headers, body) = signed_parts(&key, &device_id, "POST", "/v1/chat/completions", &body);
    let mut builder = client
        .post(format!("http://{addr}/v1/chat/completions"))
        .body(body);
    for (name, value) in headers {
        builder = builder.header(name, value);
    }
    let response = builder.send().await.unwrap();
    let id = uuid::Uuid::parse_str(
        response.headers()["x-spark-inference-attempt-id"]
            .to_str()
            .unwrap(),
    )
    .unwrap();
    let mut frames = response.bytes_stream();
    frames.next().await.unwrap().unwrap();
    let (status, clear) = signed_json(
        &client,
        addr,
        &key,
        &device_id,
        "DELETE",
        "/api/v1/inference/requests",
        None,
    )
    .await;
    assert_eq!(status, reqwest::StatusCode::OK, "{clear}");
    assert_eq!(clear["cleared"], 0);
    let path = format!("/api/v1/inference/requests/{id}/cancel");
    let key_id = uuid::Uuid::new_v4().to_string();
    let (status, receipt) = signed_json_with_idempotency(
        &client,
        addr,
        &key,
        &device_id,
        "POST",
        &path,
        None,
        Some(&key_id),
    )
    .await;
    assert_eq!(status, reqwest::StatusCode::OK, "{receipt}");
    assert_eq!(receipt["cancel_requested"], true);
    let deadline = std::time::Instant::now() + Duration::from_secs(5);
    loop {
        if h.backend.aborted_streams() > 0 {
            break;
        }
        assert!(
            std::time::Instant::now() < deadline,
            "upstream cancellation not observed"
        );
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    let (_, history) = signed_json(
        &client,
        addr,
        &key,
        &device_id,
        "GET",
        &format!("/api/v1/inference/requests?attempt_id={id}"),
        None,
    )
    .await;
    assert_eq!(history["records"][0]["outcome"], "cancelled_unconfirmed");
    let (status, replay) = signed_json_with_idempotency(
        &client,
        addr,
        &key,
        &device_id,
        "POST",
        &path,
        None,
        Some(&key_id),
    )
    .await;
    assert_eq!(status, reqwest::StatusCode::OK);
    assert_eq!(replay, receipt);
    assert_eq!(h.engine.inference_active()["active_requests"], 0);
}
