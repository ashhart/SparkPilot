#[tokio::test]
async fn failed_replacement_restores_the_last_ready_engine() {
    let (h, addr, key, device_id) = harness(240 << 30).await;
    let client = reqwest::Client::new();

    let initial_id: uuid::Uuid = load_model(&client, addr, &key, &device_id, None).await["id"]
        .as_str()
        .expect("initial load operation id")
        .parse()
        .expect("initial operation uuid");
    let initial = wait_terminal(&h.state, initial_id, Duration::from_secs(10)).await;
    assert_eq!(initial["state"], "succeeded", "{initial}");

    h.backend.fail_next_launch();
    let replacement_id: uuid::Uuid = load_model(&client, addr, &key, &device_id, Some(true)).await
        ["id"]
        .as_str()
        .expect("replacement operation id")
        .parse()
        .expect("replacement operation uuid");
    let replacement = wait_terminal(&h.state, replacement_id, Duration::from_secs(10)).await;

    assert_eq!(replacement["state"], "failed", "{replacement}");
    let active = h
        .engine
        .view()
        .expect("the last ready engine must be restored after replacement fails");
    assert_eq!(active.model_id, "example/model-32b");
    assert_eq!(active.state, sparkd::engine::EngineState::Ready);
    assert_eq!(
        h.backend.launches(),
        3,
        "initial launch, failed replacement, restored launch"
    );
}
