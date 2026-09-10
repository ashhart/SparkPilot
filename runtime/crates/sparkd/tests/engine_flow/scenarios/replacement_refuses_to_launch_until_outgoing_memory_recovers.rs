#[tokio::test]
async fn replacement_refuses_to_launch_until_outgoing_memory_recovers() {
    let (h, addr, key, device_id) = harness(240 << 30).await;
    let client = reqwest::Client::new();

    let initial_id: uuid::Uuid = load_model(&client, addr, &key, &device_id, None).await["id"]
        .as_str()
        .expect("initial load operation id")
        .parse()
        .expect("initial operation uuid");
    let initial = wait_terminal(&h.state, initial_id, Duration::from_secs(10)).await;
    assert_eq!(initial["state"], "succeeded", "{initial}");

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
    h.available.store(8 << 30, Ordering::Relaxed);
    h.backend.set_stop_blocked(false);

    let terminal = wait_terminal(&h.state, replacement_id, Duration::from_secs(10)).await;
    assert_eq!(terminal["state"], "failed", "{terminal}");
    let error_code: String = h
        .state
        .database
        .as_ref()
        .expect("db")
        .lock()
        .query_row(
            "SELECT error_code FROM operations WHERE id = ?1",
            [replacement_id.to_string()],
            |row| row.get(0),
        )
        .expect("replacement error code");
    assert_eq!(
        error_code, "outgoing engine memory did not recover after stop",
        "{terminal}"
    );
    assert_eq!(h.backend.launches(), 1, "replacement engine was launched");
    assert!(
        h.engine.view().is_none(),
        "failed replacement retained an engine instance"
    );
}
