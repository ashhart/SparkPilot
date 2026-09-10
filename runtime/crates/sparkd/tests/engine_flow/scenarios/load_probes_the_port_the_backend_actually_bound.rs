#[tokio::test]
async fn load_probes_the_port_the_backend_actually_bound() {
    let (h, addr, key, device_id) = harness(240 << 30).await;
    h.backend.set_force_fallback_port(true);
    let client = reqwest::Client::new();

    let operation_id: uuid::Uuid = load_model(&client, addr, &key, &device_id, None).await["id"]
        .as_str()
        .and_then(|value| uuid::Uuid::parse_str(value).ok())
        .expect("load operation id");
    let terminal = wait_terminal(&h.state, operation_id, Duration::from_secs(10)).await;

    assert_eq!(terminal["state"], "succeeded", "{terminal}");
    assert!(h.engine.internal_port().is_some());
}
