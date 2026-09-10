#[tokio::test]
async fn static_ipv4_is_presence_gated_and_creates_a_confirmable_operation() {
    let (developer_state, developer, developer_observed) = test_state("developer");
    let valid_body = json!({
        "address": "192.168.100.63",
        "prefix_length": 24,
        "gateway": "192.168.100.1",
        "dns_servers": ["1.1.1.1", "8.8.8.8"]
    });
    let (role_status, role_response) = send(
        developer_state,
        signed_request(
            &developer,
            Method::POST,
            "/api/v1/network/ethernet/ipv4",
            valid_body.clone(),
            true,
        ),
    )
    .await;
    assert_eq!(role_status, StatusCode::FORBIDDEN);
    assert_eq!(role_response["error"]["code"], "ROLE_FORBIDDEN");
    assert!(developer_observed.lock().unwrap().is_empty());

    let (state, client, observed) = test_state("owner");
    let (missing_presence_status, missing_presence) = send(
        state.clone(),
        signed_request(
            &client,
            Method::POST,
            "/api/v1/network/ethernet/ipv4",
            valid_body.clone(),
            false,
        ),
    )
    .await;
    assert_eq!(missing_presence_status, StatusCode::FORBIDDEN);
    assert_eq!(missing_presence["error"]["code"], "USER_PRESENCE_REQUIRED");

    let (status, response) = send(
        state.clone(),
        signed_request(
            &client,
            Method::POST,
            "/api/v1/network/ethernet/ipv4",
            valid_body,
            true,
        ),
    )
    .await;
    assert_eq!(status, StatusCode::ACCEPTED, "{response}");
    wait_for(&observed, "configure_lan_ipv4");
    let configuration_id = response["id"].as_str().unwrap();
    let (kind, input): (String, String) = {
        let connection = state.database.as_ref().unwrap().lock();
        connection
            .query_row(
                "SELECT kind, input_json FROM operations WHERE id = ?1",
                [configuration_id],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .unwrap()
    };
    assert_eq!(kind, "network.lan.ipv4");
    assert!(input.contains("\"auto_revert_seconds\":30"));
    assert!(!input.contains("interface"));
    assert!(!input.contains("connection_uuid"));
    let confirmation_path = format!("/api/v1/network/changes/{configuration_id}/confirm");
    let (confirmation_status, confirmation_response) = send(
        state,
        signed_request(&client, Method::POST, &confirmation_path, Value::Null, true),
    )
    .await;
    assert_eq!(
        confirmation_status,
        StatusCode::ACCEPTED,
        "{confirmation_response}"
    );
    wait_for(&observed, "confirm_network_change");
}
