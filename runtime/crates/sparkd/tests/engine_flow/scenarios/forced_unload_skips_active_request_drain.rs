#[tokio::test]
async fn forced_unload_skips_active_request_drain() {
    let (h, addr, key, device_id) = harness_with_drain_policy(
        240 << 30, system_clock(), Duration::ZERO, false, None, Duration::from_secs(30),
    ).await;
    let client = reqwest::Client::new();
    let load: uuid::Uuid = load_model(&client, addr, &key, &device_id, None).await["id"].as_str().unwrap().parse().unwrap();
    let loaded = wait_terminal(&h.state, load, Duration::from_secs(10)).await;
    assert_eq!(loaded["state"], "succeeded", "{loaded}");
    let (ticket, _) = h.engine.begin_request().unwrap();
    let (status, body) = signed_json(&client, addr, &key, &device_id, "POST",
        "/api/v1/inference/unload", Some(json!({"force": true}))).await;
    assert_eq!(status, reqwest::StatusCode::ACCEPTED, "{body}");
    let unload = body["id"].as_str().unwrap().parse().unwrap();
    let terminal = wait_terminal(&h.state, unload, Duration::from_secs(2)).await;
    assert_eq!(terminal["state"], "succeeded", "{terminal}");
    assert_eq!(terminal["result"]["unload"], "verified");
    assert!(h.engine.begin_request().is_err());
    drop(ticket);
}
