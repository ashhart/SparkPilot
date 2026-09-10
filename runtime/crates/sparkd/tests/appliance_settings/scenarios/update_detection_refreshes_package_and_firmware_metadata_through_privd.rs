#[tokio::test]
async fn update_detection_refreshes_package_and_firmware_metadata_through_privd() {
    let (state, client, observed) = test_state("owner");
    let (status, operation) = send(
        state,
        signed_request(
            &client,
            Method::POST,
            "/api/v1/system/updates/check",
            Value::Null,
            true,
        ),
    )
    .await;

    assert_eq!(status, StatusCode::ACCEPTED, "{operation}");
    wait_for(&observed, "refresh_system_updates");
}
