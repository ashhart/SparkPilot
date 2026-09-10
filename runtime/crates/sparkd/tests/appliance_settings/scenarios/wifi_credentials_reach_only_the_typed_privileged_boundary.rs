#[tokio::test]
async fn wifi_credentials_reach_only_the_typed_privileged_boundary() {
    let (state, client, observed) = test_state("owner");
    let secret = "never-store-this";
    let (status, operation) = send(
        state.clone(),
        signed_request(
            &client,
            Method::POST,
            "/api/v1/network/wifi",
            json!({ "ssid": "Main WiFi", "passphrase": secret, "hidden": false }),
            true,
        ),
    )
    .await;
    assert_eq!(status, StatusCode::ACCEPTED, "{operation}");
    assert!(!operation.to_string().contains(secret));
    wait_for(&observed, "connect_wifi");
    let connection = state.database.as_ref().unwrap().lock();
    let operation_input: String = connection
        .query_row(
            "SELECT input_json FROM operations WHERE kind = 'network.wifi.connect'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    let audit: String = connection
        .query_row(
            "SELECT details_json FROM audit_records WHERE action = 'network.wifi.connect'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    let events: String = connection
        .query_row(
            "SELECT COALESCE(group_concat(payload_json), '') FROM events",
            [],
            |row| row.get(0),
        )
        .unwrap();
    let settings: String = connection
        .query_row(
            "SELECT COALESCE(group_concat(value_json), '') FROM appliance_settings",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert!(!operation_input.contains(secret));
    assert!(!audit.contains(secret));
    assert!(!events.contains(secret));
    assert!(!settings.contains(secret));
    assert!(operation_input.contains("protected_input_supplied"));
}
