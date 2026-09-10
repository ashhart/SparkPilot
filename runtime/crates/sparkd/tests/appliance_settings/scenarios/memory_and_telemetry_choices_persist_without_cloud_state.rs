#[tokio::test]
async fn memory_and_telemetry_choices_persist_without_cloud_state() {
    let (state, client, _) = test_state("owner");
    let gib = 1_073_741_824_u64;
    let (memory_status, _) = send(
        state.clone(),
        signed_request(
            &client,
            Method::POST,
            "/api/v1/settings/memory-guard",
            json!({
                "warning_available_bytes": 18 * gib,
                "critical_available_bytes": 12 * gib,
                "emergency_available_bytes": 6 * gib
            }),
            true,
        ),
    )
    .await;
    assert_eq!(memory_status, StatusCode::ACCEPTED);
    for _ in 0..80 {
        let stored: i64 = state
            .database
            .as_ref()
            .unwrap()
            .lock()
            .query_row(
                "SELECT COUNT(*) FROM appliance_settings WHERE setting_key = 'memory_guard'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        if stored == 1 {
            break;
        }
        std::thread::sleep(Duration::from_millis(25));
    }
    let (status, settings) = send(
        state,
        signed_request(&client, Method::GET, "/api/v1/settings", Value::Null, false),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(
        settings["memory_guard"]["warning_available_bytes"],
        18 * gib
    );
    assert_eq!(
        settings["telemetry_consent"],
        json!({ "functional": false, "technical": false })
    );
}
