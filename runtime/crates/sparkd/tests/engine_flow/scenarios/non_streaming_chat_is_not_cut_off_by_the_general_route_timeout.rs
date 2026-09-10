#[tokio::test]
async fn non_streaming_chat_is_not_cut_off_by_the_general_route_timeout() {
    let (h, addr, key, device_id) = harness(240 << 30).await;
    let client = reqwest::Client::new();
    let operation_id: uuid::Uuid = load_model(&client, addr, &key, &device_id, None).await["id"]
        .as_str()
        .and_then(|value| uuid::Uuid::parse_str(value).ok())
        .expect("load operation id");
    wait_terminal(&h.state, operation_id, Duration::from_secs(10)).await;
    h.backend.set_non_stream_delay(Duration::from_millis(200));

    let listener = tokio::net::TcpListener::bind(("127.0.0.1", 0))
        .await
        .expect("bind short-timeout router");
    let timeout_addr = listener.local_addr().expect("short-timeout address");
    let served_state = h.state.clone();
    tokio::spawn(async move {
        axum::serve(
            listener,
            router_with_request_timeout(served_state, Duration::from_millis(50)),
        )
        .await
        .expect("serve short-timeout router");
    });

    let (status, completion) = signed_json(
        &client,
        timeout_addr,
        &key,
        &device_id,
        "POST",
        "/v1/chat/completions",
        Some(json!({
            "model": "example-32b",
            "messages": [{"role": "user", "content": "take your time"}],
            "stream": false,
        })),
    )
    .await;

    assert_eq!(status, reqwest::StatusCode::OK, "{completion}");
    assert_eq!(completion["object"], "chat.completion");
}
