#[tokio::test]
async fn update_detection_refresh_requires_fresh_owner_presence() {
    let (state, client, observed) = test_state("owner");
    let (status, error) = send(
        state,
        signed_request(
            &client,
            Method::POST,
            "/api/v1/system/updates/check",
            Value::Null,
            false,
        ),
    )
    .await;

    assert_eq!(status, StatusCode::FORBIDDEN, "{error}");
    assert_eq!(error["error"]["code"], "USER_PRESENCE_REQUIRED");
    assert!(observed.lock().unwrap().is_empty());
}
