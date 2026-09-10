#[tokio::test]
async fn load_exposes_health_check_while_readiness_probes_run() {
    let (h, addr, key, device_id) = harness(240 << 30).await;
    let client = reqwest::Client::new();
    h.backend.set_readiness_blocked(true);

    let operation_id: uuid::Uuid = load_model(&client, addr, &key, &device_id, None).await["id"]
        .as_str()
        .expect("load operation id")
        .parse()
        .expect("operation uuid");
    let deadline = std::time::Instant::now() + Duration::from_secs(2);
    while !h.backend.readiness_started() {
        assert!(
            std::time::Instant::now() < deadline,
            "readiness probing did not start"
        );
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    let (stage, progress) = {
        let conn = h.state.database.as_ref().expect("db").lock();
        let operation = h
            .state
            .jobs
            .get(&conn, operation_id)
            .expect("operation get")
            .expect("operation present");
        (operation.stage, operation.progress)
    };
    h.backend.set_readiness_blocked(false);

    assert_eq!(stage.as_deref(), Some("health_check"));
    assert_eq!(progress, Some(0.70));
    let terminal = wait_terminal(&h.state, operation_id, Duration::from_secs(10)).await;
    assert_eq!(terminal["state"], "succeeded");
}
