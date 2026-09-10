#[tokio::test]
async fn appliance_mutations_require_role_and_fresh_presence() {
    let (owner_state, owner, owner_observed) = test_state("owner");
    let (missing_status, missing) = send(
        owner_state,
        signed_request(
            &owner,
            Method::POST,
            "/api/v1/system/power-profile",
            json!({ "mode_id": 1 }),
            false,
        ),
    )
    .await;
    assert_eq!(missing_status, StatusCode::FORBIDDEN);
    assert_eq!(missing["error"]["code"], "USER_PRESENCE_REQUIRED");
    assert!(owner_observed.lock().unwrap().is_empty());

    let (user_state, user, user_observed) = test_state("user");
    let (role_status, role) = send(
        user_state,
        signed_request(
            &user,
            Method::POST,
            "/api/v1/system/power-profile",
            json!({ "mode_id": 1 }),
            true,
        ),
    )
    .await;
    assert_eq!(role_status, StatusCode::FORBIDDEN);
    assert_eq!(role["error"]["code"], "ROLE_FORBIDDEN");
    assert!(user_observed.lock().unwrap().is_empty());
}
