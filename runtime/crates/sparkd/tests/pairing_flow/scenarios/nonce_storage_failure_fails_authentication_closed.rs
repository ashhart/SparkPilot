#[tokio::test]
async fn nonce_storage_failure_fails_authentication_closed() {
    let peer = full_peer();
    let (invitation, _) = bootstrap_owner_invitation(&peer);
    let (status, _) = run_claim(&peer, &invitation, &peer, "Test Device", "macos").await;
    assert_eq!(status, StatusCode::CREATED);
    peer.state
        .database
        .as_ref()
        .unwrap()
        .lock()
        .execute("DROP TABLE request_nonces", [])
        .unwrap();

    let response = router(peer.state.clone())
        .oneshot(signed_request(
            &peer,
            Method::GET,
            "/api/v1/identity",
            &[],
            &fresh_nonce(),
            &rfc3339_now(),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::INTERNAL_SERVER_ERROR);
    let bytes = to_bytes(response.into_body(), 1 << 20).await.unwrap();
    let envelope: Value = serde_json::from_slice(&bytes).unwrap();
    assert_eq!(envelope["error"]["code"], "INTERNAL_ERROR");
}
