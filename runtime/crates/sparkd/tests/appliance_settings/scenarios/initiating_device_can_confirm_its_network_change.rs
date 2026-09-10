#[tokio::test]
async fn initiating_device_can_confirm_its_network_change() {
    let (state, initiating_client, observed) = test_state("owner");
    let configuration_id = {
        let connection = state.database.as_ref().unwrap().lock();
        let operation_id = state
            .jobs
            .create(
                &connection,
                "network.direct_ethernet",
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
        signed_request(&initiating_client, Method::POST, &path, Value::Null, true),
    )
    .await;

    assert_eq!(status, StatusCode::ACCEPTED, "{response}");
    wait_for(&observed, "confirm_network_change");
}
