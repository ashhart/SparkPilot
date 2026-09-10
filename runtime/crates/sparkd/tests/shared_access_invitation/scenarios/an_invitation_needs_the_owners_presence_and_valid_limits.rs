#[tokio::test]
async fn an_invitation_needs_the_owners_presence_and_valid_limits() {
    let node = node();
    let body = serde_json::to_vec(&limits()).expect("body");
    let (status, refused) = run(
        &node,
        signed(
            &node.owner.device,
            &node.owner.device_id,
            Method::POST,
            "/api/v1/shared-access/invitations",
            &body,
            &rfc3339_now(),
            &fresh_nonce(),
        ),
    )
    .await;
    assert_eq!(status, StatusCode::FORBIDDEN, "{refused}");
    assert_eq!(error_code(&refused), "USER_PRESENCE_REQUIRED");

    let mut bad = limits();
    bad["daily_token_budget"] = json!(0);
    let body = serde_json::to_vec(&bad).expect("body");
    let (status, refused) = run(
        &node,
        with_presence(&node, Method::POST, "/api/v1/shared-access/invitations", &body),
    )
    .await;
    assert_eq!(status, StatusCode::UNPROCESSABLE_ENTITY, "{refused}");
    assert_eq!(error_code(&refused), "SHARED_ACCESS_POLICY_INVALID");

    let mut bad = limits();
    bad["time_zone"] = json!("../../etc/passwd");
    let body = serde_json::to_vec(&bad).expect("body");
    let (status, refused) = run(
        &node,
        with_presence(&node, Method::POST, "/api/v1/shared-access/invitations", &body),
    )
    .await;
    assert_eq!(status, StatusCode::UNPROCESSABLE_ENTITY, "{refused}");
    assert_eq!(error_code(&refused), "SHARED_ACCESS_POLICY_INVALID");
}
