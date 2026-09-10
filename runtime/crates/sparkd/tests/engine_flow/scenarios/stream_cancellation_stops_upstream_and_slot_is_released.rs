#[tokio::test]
async fn stream_cancellation_stops_upstream_and_slot_is_released() {
    let (h, addr, key, device_id) = harness(240 << 30).await;
    h.backend.set_stall_after_first(true);
    let client = reqwest::Client::new();

    let operation_id: uuid::Uuid = load_model(&client, addr, &key, &device_id, None).await["id"]
        .as_str()
        .and_then(|s| uuid::Uuid::parse_str(s).ok())
        .expect("load operation id");
    wait_terminal(&h.state, operation_id, Duration::from_secs(10)).await;

    // Open a stalled stream; the stub holds after the first chunk.
    let (headers, bytes) = signed_parts(
        &key,
        &device_id,
        "POST",
        "/v1/chat/completions",
        &serde_json::to_vec(&json!({
            "model": "example-32b",
            "messages": [{"role": "user", "content": "cancel me"}],
            "stream": true,
        }))
        .unwrap(),
    );
    let mut builder = client
        .post(format!("http://{addr}/v1/chat/completions"))
        .body(bytes);
    for (name, value) in headers {
        builder = builder.header(name, value);
    }
    let response = builder.send().await.expect("stream open");
    let mut frame_stream = response.bytes_stream();
    let first = futures::StreamExt::next(&mut frame_stream)
        .await
        .expect("first frame present")
        .expect("first frame ok");
    assert!(String::from_utf8_lossy(&first).contains("chat.completion.chunk"));

    let (_, active) = status_and_active_inference(&client, addr, &key, &device_id).await;
    assert_eq!(active["state"], "ready", "{active}");
    assert_eq!(active["active_requests"], 1, "{active}");

    drop(frame_stream); // client cancellation: dropping the stream closes the link

    // The upstream stub must observe the disconnect and the slot must free.
    let deadline = std::time::Instant::now() + Duration::from_secs(5);
    loop {
        if h.backend.aborted_streams() >= 1 {
            break;
        }
        assert!(
            std::time::Instant::now() < deadline,
            "upstream abort not observed"
        );
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    let (_, active) = status_and_active_inference(&client, addr, &key, &device_id).await;
    assert_eq!(active["state"], "idle", "{active}");
    assert_eq!(active["active_requests"], 0, "{active}");
}
