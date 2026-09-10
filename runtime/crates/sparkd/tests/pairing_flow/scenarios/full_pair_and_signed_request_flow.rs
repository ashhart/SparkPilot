#[tokio::test]
async fn full_pair_and_signed_request_flow() {
    let peer = full_peer();
    let (invitation, _installer) = bootstrap_owner_invitation(&peer);

    let (status, claim) = run_claim(&peer, &invitation, &peer, "Test Device", "macos").await;
    assert_eq!(status, StatusCode::CREATED, "pairing claim accepted");
    let claim = claim.expect("claim body");
    assert_eq!(claim["device"]["role"].as_str().unwrap(), "owner");
    assert_eq!(
        claim["device"]["id"].as_str().unwrap(),
        peer.device_id.to_string()
    );
    let (stored_presence_key, stored_device_fingerprint): (Vec<u8>, String) = peer
        .state
        .database
        .as_ref()
        .unwrap()
        .lock()
        .query_row(
            "SELECT presence_public_key_spki, public_key_fingerprint
               FROM devices WHERE id = ?1",
            rusqlite::params![peer.device_id.to_string()],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .unwrap();
    assert_eq!(stored_presence_key, spki_der(&peer.presence_key));
    assert_eq!(
        stored_device_fingerprint,
        sha256_hex(&canonical_point(&peer.device_key))
    );
    assert_eq!(
        claim["presence_key_fingerprint"],
        presence_key_fingerprint(&peer.presence_key)
    );
    let _: spark_contracts::generated::PairingGrant =
        serde_json::from_value(claim.clone()).expect("claim matches PairingGrant contract");
    let pairing_audit = audit_rows(&peer, "pairing.invitation.claimed");
    assert_eq!(pairing_audit.len(), 1);
    assert_eq!(pairing_audit[0].0, peer.device_id.to_string());
    assert_eq!(pairing_audit[0].1, "owner");
    assert_eq!(pairing_audit[0].2, format!("device/{}", peer.device_id));
    assert_eq!(pairing_audit[0].3, "succeeded");
    assert_eq!(pairing_audit[0].4, "{}");

    // Signed request against a protected endpoint.
    let request = signed_request(
        &peer,
        Method::GET,
        "/api/v1/identity",
        &[],
        &fresh_nonce(),
        &rfc3339_now(),
    );
    let response = router(peer.state.clone()).oneshot(request).await.unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    let bytes = to_bytes(response.into_body(), 1 << 20).await.unwrap();
    let identity: Value = serde_json::from_slice(&bytes).unwrap();
    assert_eq!(
        identity["node_id"].as_str().unwrap(),
        peer.identity.node_id().to_string()
    );

    // Recover lost claim responses only for the granted key, rechecking all stored bindings without creating another grant.
    let (status, body) = send_json(
        &peer,
        Method::POST,
        "/api/v1/pairing/challenge",
        json!({
            "invitation_id": invitation.invitation_id,
            "device_public_key_spki": spki_b64(&peer.device_key),
        }),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "exact grant recovery is available");
    assert!(body.is_some());

    let stranger = full_peer();
    let (status, body) = send_json(
        &peer,
        Method::POST,
        "/api/v1/pairing/challenge",
        json!({
            "invitation_id": invitation.invitation_id,
            "device_public_key_spki": spki_b64(&stranger.device_key),
        }),
    )
    .await;
    assert_eq!(status, StatusCode::CONFLICT);
    assert_eq!(body.unwrap()["error"]["code"], "INVITATION_ALREADY_USED");
}
