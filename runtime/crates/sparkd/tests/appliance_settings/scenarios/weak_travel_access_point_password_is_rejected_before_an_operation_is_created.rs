#[tokio::test]
async fn weak_travel_access_point_password_is_rejected_before_an_operation_is_created() {
    let (state, client, observed) = test_state("owner");
    let (status, response) = send(
        state.clone(),
        signed_request(
            &client,
            Method::POST,
            "/api/v1/network/travel-ap",
            json!({
                "enabled": true,
                "ssid": "Spark-Travel",
                "passphrase": "short"
            }),
            true,
        ),
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert_eq!(response["error"]["code"], "INVALID_TRAVEL_ACCESS_POINT");
    assert!(observed.lock().unwrap().is_empty());
    let operation_count: i64 = state
        .database
        .as_ref()
        .unwrap()
        .lock()
        .query_row("SELECT COUNT(*) FROM operations", [], |row| row.get(0))
        .unwrap();
    assert_eq!(operation_count, 0);
}
