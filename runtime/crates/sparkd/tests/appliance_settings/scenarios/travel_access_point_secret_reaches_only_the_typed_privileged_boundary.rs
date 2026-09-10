#[tokio::test]
async fn travel_access_point_secret_reaches_only_the_typed_privileged_boundary() {
    let (state, client, observed) = test_state("owner");
    let secret = "correct-horse-battery";
    let (status, response) = send(
        state.clone(),
        signed_request(
            &client,
            Method::POST,
            "/api/v1/network/travel-ap",
            json!({
                "enabled": true,
                "ssid": "Spark-Travel",
                "passphrase": secret
            }),
            true,
        ),
    )
    .await;
    assert_eq!(status, StatusCode::ACCEPTED, "{response}");
    assert!(!response.to_string().contains(secret));
    wait_for(&observed, "configure_travel_ap");
    let connection = state.database.as_ref().unwrap().lock();
    let durable_text: String = connection
        .query_row(
            "SELECT input_json || ' ' || COALESCE(result_json, '') FROM operations WHERE kind = 'network.travel_access_point'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    let audit: String = connection
        .query_row(
            "SELECT details_json FROM audit_records WHERE action = 'network.travel_access_point'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert!(!durable_text.contains(secret));
    assert!(!audit.contains(secret));
}
