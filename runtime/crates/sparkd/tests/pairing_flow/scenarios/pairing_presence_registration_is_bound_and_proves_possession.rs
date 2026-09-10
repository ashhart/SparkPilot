#[tokio::test]
async fn pairing_presence_registration_is_bound_and_proves_possession() {
    let peer = full_peer();
    let (invitation, _) = bootstrap_owner_invitation(&peer);
    let claimant = full_peer();
    let attacker_presence_key = fresh_device_key();
    let (challenge_id, challenge_bytes) = pairing_challenge(&peer, &invitation, &claimant).await;

    let intended_fingerprint = presence_key_fingerprint(&claimant.presence_key);
    let submitted_fingerprint = presence_key_fingerprint(&attacker_presence_key);
    let device_signature = device_challenge_signature(
        &claimant,
        peer.identity.node_id(),
        &challenge_bytes,
        &invitation.invitation_id,
        Some(&intended_fingerprint),
    );
    let submitted_material = pairing_claim_material(
        &claimant,
        peer.identity.node_id(),
        &challenge_bytes,
        &invitation.invitation_id,
        Some(&submitted_fingerprint),
    );
    let presence_signature: p256::ecdsa::Signature =
        attacker_presence_key.sign(&submitted_material);
    let (status, body) = send_json(
        &peer,
        Method::POST,
        "/api/v1/pairing/claim",
        json!({
            "invitation": invitation,
            "challenge_id": challenge_id,
            "device_id": claimant.device_id,
            "device_name": "Substituted Presence Key",
            "platform": "ios",
            "device_public_key_spki": spki_b64(&claimant.device_key),
            "presence_public_key_spki": spki_b64(&attacker_presence_key),
            "presence_key_signature": base64url_encode(&presence_signature.to_bytes()),
            "challenge_signature": device_signature,
        }),
    )
    .await;
    assert_eq!(status, StatusCode::UNAUTHORIZED, "{body:?}");
    assert_eq!(body.unwrap()["error"]["code"], "SIGNATURE_INVALID");
    let granted: i64 = peer
        .state
        .database
        .as_ref()
        .unwrap()
        .lock()
        .query_row(
            "SELECT COUNT(*) FROM devices WHERE id = ?1",
            rusqlite::params![claimant.device_id.to_string()],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(granted, 0);

    let peer = full_peer();
    let (invitation, _) = bootstrap_owner_invitation(&peer);
    let claimant = full_peer();
    let (challenge_id, challenge_bytes) = pairing_challenge(&peer, &invitation, &claimant).await;
    let fingerprint = presence_key_fingerprint(&claimant.presence_key);
    let material = pairing_claim_material(
        &claimant,
        peer.identity.node_id(),
        &challenge_bytes,
        &invitation.invitation_id,
        Some(&fingerprint),
    );
    let device_signature: p256::ecdsa::Signature = claimant.device_key.sign(&material);
    let wrong_key = fresh_device_key();
    let wrong_presence_signature: p256::ecdsa::Signature = wrong_key.sign(&material);
    let (status, body) = send_json(
        &peer,
        Method::POST,
        "/api/v1/pairing/claim",
        json!({
            "invitation": invitation,
            "challenge_id": challenge_id,
            "device_id": claimant.device_id,
            "device_name": "Unproved Presence Key",
            "platform": "ios",
            "device_public_key_spki": spki_b64(&claimant.device_key),
            "presence_public_key_spki": spki_b64(&claimant.presence_key),
            "presence_key_signature": base64url_encode(&wrong_presence_signature.to_bytes()),
            "challenge_signature": base64url_encode(&device_signature.to_bytes()),
        }),
    )
    .await;
    assert_eq!(status, StatusCode::UNAUTHORIZED, "{body:?}");
    assert_eq!(body.unwrap()["error"]["code"], "SIGNATURE_INVALID");
}
