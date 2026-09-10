#[tokio::test]
async fn open_webui_repair_is_durable_idempotent_and_recovers_pending_gateway() {
    let (state, client, observed) = test_state("owner");
    seed_repair_gateway(&state, &client, true);
    let key = uuid::Uuid::new_v4().to_string();
    let make = || {
        let mut request = signed_request(
            &client,
            Method::POST,
            "/api/v1/services/open-webui/repair",
            Value::Null,
            true,
        );
        request
            .headers_mut()
            .insert("idempotency-key", key.parse().unwrap());
        request
    };
    let (status, original) = send(state.clone(), make()).await;
    assert_eq!(status, StatusCode::ACCEPTED, "{original}");
    wait_for(&observed, "repair_open_webui");
    let (status, replay) = send(state.clone(), make()).await;
    assert_eq!(status, StatusCode::ACCEPTED, "{replay}");
    assert!(original["id"].as_str().is_some());
    assert_eq!(original["id"], replay["id"]);
    assert_eq!(
        observed
            .lock()
            .unwrap()
            .iter()
            .filter(|kind| kind.as_str() == "repair_open_webui")
            .count(),
        1
    );
    let deadline = std::time::Instant::now() + Duration::from_secs(2);
    loop {
        let configured: (bool, bool) = state.database.as_ref().unwrap().lock().query_row(
            "SELECT enabled, pending_install FROM optional_services WHERE service_id = 'open-webui'",
            [], |row| Ok((row.get(0)?, row.get(1)?)),
        ).unwrap();
        if configured == (true, false) {
            break;
        }
        assert!(
            std::time::Instant::now() < deadline,
            "repair did not finish gateway reconciliation"
        );
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    let count: i64 = state
        .database
        .as_ref()
        .unwrap()
        .lock()
        .query_row(
            "SELECT COUNT(*) FROM operations WHERE kind = 'service.open_webui.repair'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(count, 1);
}
