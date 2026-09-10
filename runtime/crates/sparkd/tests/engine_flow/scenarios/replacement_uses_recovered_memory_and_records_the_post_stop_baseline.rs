#[tokio::test]
async fn replacement_uses_recovered_memory_and_records_the_post_stop_baseline() {
    let (h, addr, key, device_id) = harness(240 << 30).await;
    let client = reqwest::Client::new();

    let initial_id: uuid::Uuid = load_model(&client, addr, &key, &device_id, None).await["id"]
        .as_str()
        .expect("initial load operation id")
        .parse()
        .expect("initial operation uuid");
    let initial = wait_terminal(&h.state, initial_id, Duration::from_secs(10)).await;
    assert_eq!(initial["state"], "succeeded", "{initial}");

    // Project replacement recovery from the outgoing 240 GiB baseline even when current free memory cannot fit the incoming model.
    h.available.store(8 << 30, Ordering::Relaxed);
    h.backend.set_stop_blocked(true);
    let replacement_id: uuid::Uuid = load_model(&client, addr, &key, &device_id, Some(true)).await
        ["id"]
        .as_str()
        .expect("replacement operation id")
        .parse()
        .expect("replacement operation uuid");
    let deadline = std::time::Instant::now() + Duration::from_secs(2);
    while !h.backend.stop_started() {
        assert!(
            std::time::Instant::now() < deadline,
            "outgoing engine stop did not start"
        );
        tokio::time::sleep(Duration::from_millis(10)).await;
    }

    // Capture actual recovered memory within the 256 MiB tolerance instead of retaining the projected outgoing baseline.
    let recovered_available = (240 << 30) - (200 << 20);
    h.available.store(recovered_available, Ordering::Relaxed);
    h.backend.set_stop_blocked(false);
    let replacement = wait_terminal(&h.state, replacement_id, Duration::from_secs(10)).await;
    assert_eq!(replacement["state"], "succeeded", "{replacement}");

    // Use memory 100 MiB below the incoming baseline but 300 MiB below the outgoing one to distinguish recorded baselines.
    h.available
        .store(recovered_available - (100 << 20), Ordering::Relaxed);

    let (unload_status, unload_body) = signed_json(
        &client,
        addr,
        &key,
        &device_id,
        "POST",
        "/api/v1/inference/unload",
        Some(json!({})),
    )
    .await;
    assert_eq!(
        unload_status,
        reqwest::StatusCode::ACCEPTED,
        "{unload_body}"
    );
    let unload_id = unload_body["id"]
        .as_str()
        .and_then(|id| uuid::Uuid::parse_str(id).ok())
        .expect("unload operation id");
    let unloaded = wait_terminal(&h.state, unload_id, Duration::from_secs(10)).await;
    assert_eq!(unloaded["state"], "succeeded", "{unloaded}");
}
