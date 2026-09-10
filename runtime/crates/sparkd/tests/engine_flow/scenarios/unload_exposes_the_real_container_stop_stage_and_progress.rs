#[tokio::test]
async fn unload_exposes_the_real_container_stop_stage_and_progress() {
    let (h, addr, key, device_id) = harness(240 << 30).await;
    let client = reqwest::Client::new();
    let load_id: uuid::Uuid = load_model(&client, addr, &key, &device_id, None).await["id"]
        .as_str()
        .expect("load operation id")
        .parse()
        .expect("load operation uuid");
    let loaded = wait_terminal(&h.state, load_id, Duration::from_secs(10)).await;
    assert_eq!(loaded["state"], "succeeded", "{loaded}");

    h.backend.set_stop_blocked(true);
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
        .expect("unload operation id")
        .parse()
        .expect("unload operation uuid");
    let deadline = std::time::Instant::now() + Duration::from_secs(2);
    while !h.backend.stop_started() {
        assert!(
            std::time::Instant::now() < deadline,
            "container stop did not start"
        );
        tokio::time::sleep(Duration::from_millis(10)).await;
    }

    let (stage, progress) = {
        let conn = h.state.database.as_ref().expect("db").lock();
        let operation = h
            .state
            .jobs
            .get(&conn, unload_id)
            .expect("operation get")
            .expect("operation present");
        (operation.stage, operation.progress)
    };
    assert_eq!(stage.as_deref(), Some("stopping"));
    assert_eq!(progress, Some(0.50));

    h.backend.set_stop_blocked(false);
    let terminal = wait_terminal(&h.state, unload_id, Duration::from_secs(10)).await;
    assert_eq!(terminal["state"], "succeeded", "{terminal}");
    assert_eq!(terminal["stage"], "unloaded", "{terminal}");
    assert_eq!(terminal["progress"], 1.0, "{terminal}");
}
