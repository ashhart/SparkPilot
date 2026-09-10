#[tokio::test]
async fn network_mutations_require_administrator_authority_and_fresh_presence() {
    let (developer_state, developer, developer_observed) = test_state("developer");
    let (role_status, role_response) = send(
        developer_state,
        signed_request(
            &developer,
            Method::POST,
            "/api/v1/network/direct-profile",
            json!({ "enabled": true }),
            true,
        ),
    )
    .await;
    assert_eq!(role_status, StatusCode::FORBIDDEN);
    assert_eq!(role_response["error"]["code"], "ROLE_FORBIDDEN");
    assert!(developer_observed.lock().unwrap().is_empty());

    let (owner_state, owner, owner_observed) = test_state("owner");
    let (presence_status, presence_response) = send(
        owner_state,
        signed_request(
            &owner,
            Method::POST,
            "/api/v1/network/direct-profile",
            json!({ "enabled": true }),
            false,
        ),
    )
    .await;
    assert_eq!(presence_status, StatusCode::FORBIDDEN);
    assert_eq!(presence_response["error"]["code"], "USER_PRESENCE_REQUIRED");
    assert!(owner_observed.lock().unwrap().is_empty());
}
