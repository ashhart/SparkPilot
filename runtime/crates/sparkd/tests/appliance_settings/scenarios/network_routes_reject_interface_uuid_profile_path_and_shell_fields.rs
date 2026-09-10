#[tokio::test]
async fn network_routes_reject_interface_uuid_profile_path_and_shell_fields() {
    let (state, client, observed) = test_state("owner");
    let (status, response) = send(
        state,
        signed_request(
            &client,
            Method::POST,
            "/api/v1/network/direct-profile",
            json!({
                "enabled": true,
                "interface": "enp1s0np0",
                "connection_uuid": uuid::Uuid::new_v4(),
                "profile_path": "/etc/NetworkManager/system-connections/unsafe.nmconnection",
                "shell": "touch /tmp/unsafe"
            }),
            true,
        ),
    )
    .await;

    assert_eq!(status, StatusCode::UNPROCESSABLE_ENTITY, "{response}");
    assert!(observed.lock().unwrap().is_empty());
}
