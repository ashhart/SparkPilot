#[tokio::test]
async fn a_different_paired_device_cannot_confirm_a_network_change() {
    let (state, initiating_client, observed) = test_state("owner");
    let confirming_client = test_client();
    let configuration_id = {
        let connection = state.database.as_ref().unwrap().lock();
        insert_test_client(&connection, &confirming_client, "administrator");
        let operation_id = state
            .jobs
            .create(
                &connection,
                "network.wifi.connect",
                initiating_client.device_id,
                None,
                "{}",
            )
            .unwrap();
        connection
            .execute(
                "UPDATE operations SET state = 'succeeded' WHERE id = ?1",
                [operation_id.to_string()],
            )
            .unwrap();
        operation_id
    };
    let path = format!("/api/v1/network/changes/{configuration_id}/confirm");

    let (status, response) = send(
        state,
        signed_request(&confirming_client, Method::POST, &path, Value::Null, true),
    )
    .await;

    assert_eq!(status, StatusCode::FORBIDDEN, "{response}");
    assert_eq!(response["error"]["code"], "NETWORK_CONFIRMATION_FORBIDDEN");
    assert!(
        !observed
            .lock()
            .unwrap()
            .iter()
            .any(|kind| kind == "confirm_network_change"),
        "a second device reached the privileged confirmation boundary"
    );
}
