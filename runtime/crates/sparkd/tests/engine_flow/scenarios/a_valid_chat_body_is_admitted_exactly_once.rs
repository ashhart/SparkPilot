/// Require valid bodies to be admitted exactly once so a proxy rejecting everything cannot satisfy refusal-only tests.
#[tokio::test]
async fn a_valid_chat_body_is_admitted_exactly_once() {
    let (h, addr, key, device_id) = harness(240 << 30).await;
    let client = reqwest::Client::new();
    let operation_id: uuid::Uuid = load_model(&client, addr, &key, &device_id, None).await["id"]
        .as_str()
        .expect("load operation id")
        .parse()
        .expect("operation uuid");
    let loaded = wait_terminal(&h.state, operation_id, Duration::from_secs(10)).await;
    assert_eq!(loaded["state"], "succeeded", "{loaded}");

    let idle_before = h.engine.last_activity();
    let served_before = h.backend.completions();
    let (status, completion) = signed_json(
        &client,
        addr,
        &key,
        &device_id,
        "POST",
        "/v1/chat/completions",
        Some(json!({
            "model": "example-32b",
            "messages": [{"role": "user", "content": "hi"}],
            "max_tokens": 16,
            "stream": false,
        })),
    )
    .await;
    assert_eq!(status, reqwest::StatusCode::OK, "{completion}");
    assert_eq!(
        h.backend.completions(),
        served_before + 1,
        "the engine served the request more than once, or not at all"
    );
    assert_ne!(
        h.engine.last_activity(),
        idle_before,
        "an admitted request did not move the idle clock"
    );
    let view = h.engine.view().expect("engine loaded");
    assert_eq!(
        view.active_requests, 0,
        "the admitted request released its slot more or less than once"
    );
}
