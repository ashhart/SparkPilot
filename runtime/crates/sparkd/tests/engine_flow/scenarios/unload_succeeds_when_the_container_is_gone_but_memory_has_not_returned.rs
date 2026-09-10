#[tokio::test]
async fn unload_succeeds_when_the_container_is_gone_but_memory_has_not_returned() {
    let (h, addr, key, device_id) = harness(240 << 30).await;
    let client = reqwest::Client::new();

    let operation_id: uuid::Uuid = load_model(&client, addr, &key, &device_id, None).await["id"]
        .as_str()
        .and_then(|s| uuid::Uuid::parse_str(s).ok())
        .expect("load operation id");
    wait_terminal(&h.state, operation_id, Duration::from_secs(10)).await;

    // Keep memory below baseline throughout recovery to prove cached weights cannot turn a verified container stop into failed unload.
    h.available.store(8 << 30, Ordering::Relaxed); // baseline was 240 GiB

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
    let operation_id: uuid::Uuid = body["id"]
        .as_str()
        .and_then(|s| uuid::Uuid::parse_str(s).ok())
        .expect("unload operation id");
    let terminal = wait_terminal(&h.state, operation_id, Duration::from_secs(10)).await;
    assert_eq!(terminal["state"], "succeeded", "{terminal}");
    // Report memory recovery separately from the successful container-stop verdict.
    assert_eq!(
        terminal["result"]["memory_recovered"],
        json!(false),
        "{terminal}"
    );

    let (_, active) = signed_json(
        &client,
        addr,
        &key,
        &device_id,
        "GET",
        "/api/v1/inference/active",
        None,
    )
    .await;
    assert_eq!(active["state"], "unloaded", "{active}");
}
