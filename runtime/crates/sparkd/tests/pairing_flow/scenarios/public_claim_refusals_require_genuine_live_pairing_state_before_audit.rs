#[tokio::test]
async fn public_claim_refusals_require_genuine_live_pairing_state_before_audit() {
    let peer = full_peer();
    let (invitation, _) = bootstrap_owner_invitation(&peer);
    let mut forged_invitation = invitation.clone();
    forged_invitation.signature = Some("not-a-node-signature".into());
    let (status, _) = send_json(
        &peer,
        Method::POST,
        "/api/v1/pairing/claim",
        json!({
            "invitation": forged_invitation,
            "challenge_id": uuid::Uuid::new_v4(),
            "device_id": peer.device_id,
            "device_name": "Untrusted Device",
            "platform": "ios",
            "device_public_key_spki": spki_b64(&peer.device_key),
            "challenge_signature": base64url_encode(&[0_u8; 64]),
        }),
    )
    .await;
    assert_eq!(status, StatusCode::UNPROCESSABLE_ENTITY);
    assert!(
        audit_rows(&peer, "pairing.invitation.claimed").is_empty(),
        "arbitrary public garbage must not amplify durable audit writes"
    );

    let (challenge_id, _) = pairing_challenge(&peer, &invitation, &peer).await;
    let (status, body) = send_json(
        &peer,
        Method::POST,
        "/api/v1/pairing/claim",
        json!({
            "invitation": invitation,
            "challenge_id": challenge_id,
            "device_id": peer.device_id,
            "device_name": "Known Pairing Device",
            "platform": "ios",
            "device_public_key_spki": spki_b64(&peer.device_key),
            "challenge_signature": base64url_encode(&[0_u8; 64]),
        }),
    )
    .await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);
    assert_eq!(body.unwrap()["error"]["code"], "SIGNATURE_INVALID");
    let rows = audit_rows(&peer, "pairing.invitation.claimed");
    assert_eq!(rows.len(), 1);
    assert_eq!(rows[0].0, "");
    assert_eq!(rows[0].1, "");
    assert_eq!(rows[0].2, "");
    assert_eq!(rows[0].3, "refused");
    assert_eq!(
        serde_json::from_str::<Value>(&rows[0].4).unwrap()["reason_code"],
        "SIGNATURE_INVALID"
    );
}
