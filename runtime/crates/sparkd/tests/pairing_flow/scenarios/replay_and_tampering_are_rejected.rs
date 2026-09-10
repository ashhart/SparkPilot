#[tokio::test]
async fn replay_and_tampering_are_rejected() {
    let peer = full_peer();
    let (invitation, _installer) = bootstrap_owner_invitation(&peer);
    let (status, _) = run_claim(&peer, &invitation, &peer, "Test Device", "macos").await;
    assert_eq!(status, StatusCode::CREATED);

    // Replay a signed request verbatim → nonce reuse must be rejected.
    let nonce = fresh_nonce();
    let timestamp = rfc3339_now();
    let first = router(peer.state.clone())
        .oneshot(signed_request(
            &peer,
            Method::GET,
            "/api/v1/identity",
            &[],
            &nonce,
            &timestamp,
        ))
        .await
        .unwrap();
    assert_eq!(first.status(), StatusCode::OK);

    let second = router(peer.state.clone())
        .oneshot(signed_request(
            &peer,
            Method::GET,
            "/api/v1/identity",
            &[],
            &nonce,
            &timestamp,
        ))
        .await
        .unwrap();
    assert_eq!(
        second.status(),
        StatusCode::CONFLICT,
        "replayed nonce rejected"
    );
    let bytes = to_bytes(second.into_body(), 1 << 20).await.unwrap();
    let envelope: Value = serde_json::from_slice(&bytes).unwrap();
    assert_eq!(envelope["error"]["code"], "REQUEST_REPLAYED");

    // Tamper: signature over a different content digest must be rejected.
    let tampered_nonce = fresh_nonce();
    let canonical = auth::canonical(
        "GET",
        "/api/v1/identity",
        &timestamp,
        &tampered_nonce,
        &sha256_hex(b"different body"),
        &peer.device_id,
        &SIGNING_NODE_ID,
    );
    let tampered_signature: p256::ecdsa::Signature = peer.device_key.sign(canonical.as_bytes());
    let sig = base64url_encode(&tampered_signature.to_bytes());
    let tampered = Request::builder()
        .method(Method::GET)
        .uri("/api/v1/identity")
        .header(auth::HEADER_DEVICE_ID, peer.device_id.to_string())
        .header("x-spark-node-id", SIGNING_NODE_ID.to_string())
        .header(auth::HEADER_TIMESTAMP, timestamp)
        .header(auth::HEADER_NONCE, tampered_nonce)
        .header(auth::HEADER_CONTENT_SHA256, sha256_hex(b"different body"))
        .header(auth::HEADER_SIGNATURE, sig)
        .body(axum::body::Body::empty())
        .unwrap();
    let status = router(peer.state.clone())
        .oneshot(tampered)
        .await
        .unwrap()
        .status();
    assert_eq!(status, StatusCode::UNAUTHORIZED, "body tampering rejected");
}
