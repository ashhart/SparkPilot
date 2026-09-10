/// Unload succeeds on container evidence, but the memory verdict must stay visible to the owner afterwards (M-6).
#[tokio::test]
async fn an_unload_that_does_not_reclaim_memory_says_so() {
    let (h, addr, key, device_id) = harness(240 << 30).await;
    let client = reqwest::Client::new();
    let load: uuid::Uuid = load_model(&client, addr, &key, &device_id, None).await["id"]
        .as_str()
        .unwrap()
        .parse()
        .unwrap();
    let loaded = wait_terminal(&h.state, load, Duration::from_secs(10)).await;
    assert_eq!(loaded["state"], "succeeded", "{loaded}");
    // The engine's memory never comes back: something still holds it after the container stops.
    h.available.store(40 << 30, Ordering::Relaxed);
    let (status, body) = signed_json(
        &client, addr, &key, &device_id, "POST", "/api/v1/inference/unload", Some(json!({})),
    )
    .await;
    assert_eq!(status, reqwest::StatusCode::ACCEPTED, "{body}");
    let unload = body["id"].as_str().unwrap().parse().unwrap();
    let terminal = wait_terminal(&h.state, unload, Duration::from_secs(5)).await;
    assert_eq!(terminal["state"], "succeeded", "{terminal}");
    assert_eq!(terminal["result"]["memory_recovered"], false);
    let (status, active) = signed_json(
        &client, addr, &key, &device_id, "GET", "/api/v1/inference/active", None,
    )
    .await;
    assert_eq!(status, reqwest::StatusCode::OK, "{active}");
    assert_eq!(active["state"], "unloaded");
    assert_eq!(active["last_unload"]["memory_recovered"], false, "{active}");
    assert_eq!(active["last_unload"]["baseline_bytes"], json!(240u64 << 30));
    assert_eq!(active["last_unload"]["available_bytes"], json!(40u64 << 30));
    assert!(active["last_unload"]["model_id"].is_string());
}
