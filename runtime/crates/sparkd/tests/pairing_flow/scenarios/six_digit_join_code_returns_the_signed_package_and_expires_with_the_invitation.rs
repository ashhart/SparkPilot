#[tokio::test]
async fn six_digit_join_code_returns_the_signed_package_and_expires_with_the_invitation() {
    let mut peer = full_peer();
    let tls_fingerprint = "a".repeat(64);
    peer.state.tls_fingerprint = Some(tls_fingerprint.clone());
    let (owner_invitation, _) = bootstrap_owner_invitation(&peer);
    let (status, _) = run_claim(&peer, &owner_invitation, &peer, "Owner Device", "ios").await;
    assert_eq!(status, StatusCode::CREATED);

    let invitation_body = serde_json::to_vec(&json!({
        "role": "user",
        "expires_in_seconds": 300,
    }))
    .unwrap();
    let response = router(peer.state.clone())
        .oneshot(signed_request(
            &peer,
            Method::POST,
            "/api/v1/pairing/invitations",
            &invitation_body,
            &fresh_nonce(),
            &rfc3339_now(),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::CREATED);
    let bytes = to_bytes(response.into_body(), 1 << 20).await.unwrap();
    let invitation_response: Value = serde_json::from_slice(&bytes).unwrap();
    let code = invitation_response["join_code"].as_str().unwrap();
    assert_eq!(code.len(), 6);
    assert!(code.bytes().all(|byte| byte.is_ascii_digit()));
    let invitation: pairing::InvitationPayload =
        serde_json::from_value(invitation_response.clone()).unwrap();

    let body = serde_json::to_vec(&json!({ "code": code })).unwrap();
    let request = Request::builder()
        .method(Method::POST)
        .uri("/api/v1/pairing/join-codes/redeem")
        .header("content-type", "application/json")
        .body(axum::body::Body::from(body))
        .unwrap();
    let response = router(peer.state.clone()).oneshot(request).await.unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    let bytes = to_bytes(response.into_body(), 1 << 20).await.unwrap();
    let package: Value = serde_json::from_slice(&bytes).unwrap();
    assert_eq!(package["tls_fingerprint"], tls_fingerprint);
    assert_eq!(package["node_name"], peer.identity.public.node_name);
    assert_eq!(
        package["authority_public_key"],
        peer.identity.public.authority_public_key
    );
    assert_eq!(
        package["invitation"]["invitation_id"],
        invitation.invitation_id.to_string()
    );

    let claimant = full_peer();
    let (status, _) = run_claim(&peer, &invitation, &claimant, "New Mac", "macos").await;
    assert_eq!(status, StatusCode::CREATED);
    let body = serde_json::to_vec(&json!({ "code": code })).unwrap();
    let request = Request::builder()
        .method(Method::POST)
        .uri("/api/v1/pairing/join-codes/redeem")
        .header("content-type", "application/json")
        .body(axum::body::Body::from(body))
        .unwrap();
    let response = router(peer.state.clone()).oneshot(request).await.unwrap();
    assert_eq!(response.status(), StatusCode::NOT_FOUND);
    let bytes = to_bytes(response.into_body(), 1 << 20).await.unwrap();
    let error: Value = serde_json::from_slice(&bytes).unwrap();
    assert_eq!(error["error"]["code"], "JOIN_CODE_INVALID");
}
