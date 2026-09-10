/// Parse and validate before engine admission so refused bodies cannot increment counters or reset the idle clock.
#[tokio::test]
async fn a_refused_chat_body_never_moves_the_engine_counters() {
    let (h, addr, key, device_id) = harness(240 << 30).await;
    let client = reqwest::Client::new();
    let operation_id: uuid::Uuid = load_model(&client, addr, &key, &device_id, None).await["id"]
        .as_str()
        .expect("load operation id")
        .parse()
        .expect("operation uuid");
    let loaded = wait_terminal(&h.state, operation_id, Duration::from_secs(10)).await;
    assert_eq!(loaded["state"], "succeeded", "{loaded}");

    let served_before = h.backend.completions();
    let rejections: Vec<(&str, Vec<u8>)> = vec![
        ("malformed json", b"{not json at all".to_vec()),
        (
            "truncated json",
            br#"{"model":"example-32b","messages":"#.to_vec(),
        ),
        ("not an object", b"[1,2,3]".to_vec()),
        (
            "banned parameter",
            serde_json::to_vec(&json!({
                "model": "example-32b",
                "messages": [],
                "guided_json": {"a": 1},
            }))
            .unwrap(),
        ),
        (
            "another model",
            serde_json::to_vec(&json!({
                "model": "some-other-model",
                "messages": [{"role": "user", "content": "hi"}],
            }))
            .unwrap(),
        ),
        (
            "no model at all",
            serde_json::to_vec(&json!({"messages": []})).unwrap(),
        ),
        ("oversized body", vec![b'x'; 17 * 1024 * 1024]),
    ];

    for (what, body) in rejections {
        let idle_before = h.engine.last_activity();
        let active_before = h.engine.view().expect("engine loaded").active_requests;
        assert_eq!(active_before, 0, "{what}: the engine was already busy");

        let (headers, bytes) =
            signed_parts(&key, &device_id, "POST", "/v1/chat/completions", &body);
        let mut builder = client
            .post(format!("http://{addr}/v1/chat/completions"))
            .body(bytes);
        for (name, value) in headers {
            builder = builder.header(name, value);
        }
        let response = builder.send().await.expect("send");
        let status = response.status();
        assert!(
            status.is_client_error(),
            "{what} was answered {status}, not a refusal"
        );

        let view = h.engine.view().expect("engine still loaded");
        assert_eq!(
            view.active_requests, 0,
            "{what} left the active counter at {}",
            view.active_requests
        );
        assert_eq!(
            h.engine.last_activity(),
            idle_before,
            "{what} reset the engine's idle clock"
        );
        assert_eq!(
            h.backend.completions(),
            served_before,
            "{what} reached the engine"
        );
    }
}
