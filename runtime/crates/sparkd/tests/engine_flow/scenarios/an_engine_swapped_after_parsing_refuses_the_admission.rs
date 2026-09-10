/// Revalidate the serving identity at admission when the model changes after parsing.
#[tokio::test]
async fn an_engine_swapped_after_parsing_refuses_the_admission() {
    let (h, addr, key, device_id) = harness(240 << 30).await;
    let client = reqwest::Client::new();
    let operation_id: uuid::Uuid = load_model(&client, addr, &key, &device_id, None).await["id"]
        .as_str()
        .expect("load operation id")
        .parse()
        .expect("operation uuid");
    let loaded = wait_terminal(&h.state, operation_id, Duration::from_secs(10)).await;
    assert_eq!(loaded["state"], "succeeded", "{loaded}");

    // The body parses now, while the engine it names is loaded.
    let request = sparkd::engine_api::parse_chat(
        &serde_json::to_vec(&json!({
            "model": "example-32b",
            "messages": [{"role": "user", "content": "hi"}],
        }))
        .unwrap(),
    )
    .expect("a body naming the loaded model parses");
    assert_eq!(request.requested_model, "example-32b");

    let (status, body) = signed_json(
        &client,
        addr,
        &key,
        &device_id,
        "POST",
        "/api/v1/inference/unload",
        Some(json!({})),
    )
    .await;
    assert_eq!(status, reqwest::StatusCode::ACCEPTED, "{body}");
    let unload_id: uuid::Uuid = body["id"]
        .as_str()
        .and_then(|id| uuid::Uuid::parse_str(id).ok())
        .expect("unload operation id");
    let unloaded = wait_terminal(&h.state, unload_id, Duration::from_secs(10)).await;
    assert_eq!(unloaded["state"], "succeeded", "{unloaded}");

    let refusal = h
        .engine
        .admit_request(&request.requested_model)
        .err()
        .expect("a parse from before the unload must not admit");
    assert_eq!(refusal.code(), "MODEL_NOT_LOADED");
}
