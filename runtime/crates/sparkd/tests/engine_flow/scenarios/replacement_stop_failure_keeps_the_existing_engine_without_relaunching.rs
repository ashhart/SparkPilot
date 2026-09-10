#[tokio::test]
async fn replacement_stop_failure_keeps_the_existing_engine_without_relaunching() {
    let (h, addr, key, device_id) = harness(240 << 30).await;
    let client = reqwest::Client::new();
    let initial_id: uuid::Uuid = load_model(&client, addr, &key, &device_id, None).await["id"]
        .as_str()
        .expect("initial load operation id")
        .parse()
        .expect("initial operation uuid");
    let initial = wait_terminal(&h.state, initial_id, Duration::from_secs(10)).await;
    assert_eq!(initial["state"], "succeeded", "{initial}");

    h.backend.fail_next_stop();
    let replacement_id: uuid::Uuid = load_model(&client, addr, &key, &device_id, Some(true)).await
        ["id"]
        .as_str()
        .expect("replacement operation id")
        .parse()
        .expect("replacement operation uuid");
    let failed = wait_terminal(&h.state, replacement_id, Duration::from_secs(10)).await;
    assert_eq!(failed["state"], "failed", "{failed}");

    let active = h.engine.view().expect("existing engine retained");
    assert_eq!(active.model_id, "example/model-32b");
    assert_eq!(active.state, sparkd::engine::EngineState::Ready);
    assert_eq!(h.backend.launches(), 1, "existing engine was relaunched");
    let persisted_ready: i64 = h
        .state
        .database
        .as_ref()
        .expect("db")
        .lock()
        .query_row(
            "SELECT COUNT(*) FROM inference_instances WHERE node_id = ?1 AND state = 'ready'",
            [h.state.identity.node_id().to_string()],
            |row| row.get(0),
        )
        .expect("ready instance count");
    assert_eq!(persisted_ready, 1);
}
