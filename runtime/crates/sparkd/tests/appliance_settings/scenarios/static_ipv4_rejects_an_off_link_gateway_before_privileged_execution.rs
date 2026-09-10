#[tokio::test]
async fn static_ipv4_rejects_an_off_link_gateway_before_privileged_execution() {
    let (state, client, observed) = test_state("owner");
    let (status, response) = send(
        state.clone(),
        signed_request(
            &client,
            Method::POST,
            "/api/v1/network/ethernet/ipv4",
            json!({
                "address": "192.168.100.63",
                "prefix_length": 24,
                "gateway": "192.168.50.1",
                "dns_servers": ["1.1.1.1", "8.8.8.8"]
            }),
            true,
        ),
    )
    .await;

    assert_eq!(status, StatusCode::BAD_REQUEST, "{response}");
    assert_eq!(response["error"]["code"], "INVALID_STATIC_IPV4");
    assert!(observed.lock().unwrap().is_empty());
    let operations: i64 = state
        .database
        .as_ref()
        .unwrap()
        .lock()
        .query_row("SELECT COUNT(*) FROM operations", [], |row| row.get(0))
        .unwrap();
    assert_eq!(operations, 0);
}
