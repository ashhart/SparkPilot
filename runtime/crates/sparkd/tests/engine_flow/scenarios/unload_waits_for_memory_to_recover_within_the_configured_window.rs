#[tokio::test]
async fn unload_waits_for_memory_to_recover_within_the_configured_window() {
    let (h, addr, key, device_id) = harness_with_policy(
        240 << 30,
        system_clock(),
        Duration::from_secs(1),
        false,
        None,
    )
    .await;
    let client = reqwest::Client::new();

    let operation_id: uuid::Uuid = load_model(&client, addr, &key, &device_id, None).await["id"]
        .as_str()
        .and_then(|value| uuid::Uuid::parse_str(value).ok())
        .expect("load operation id");
    wait_terminal(&h.state, operation_id, Duration::from_secs(10)).await;

    h.available.store(8 << 30, Ordering::Relaxed);
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
    let operation_id = body["id"]
        .as_str()
        .and_then(|value| uuid::Uuid::parse_str(value).ok())
        .expect("unload operation id");

    let available = h.available.clone();
    tokio::spawn(async move {
        tokio::time::sleep(Duration::from_millis(100)).await;
        available.store(240 << 30, Ordering::Relaxed);
    });

    let terminal = wait_terminal(&h.state, operation_id, Duration::from_secs(10)).await;
    assert_eq!(terminal["state"], "succeeded", "{terminal}");
}
