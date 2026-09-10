#[tokio::test]
async fn alternate_spki_encoding_cannot_hide_reuse_of_the_device_key() {
    let peer = full_peer();
    let (invitation, _) = bootstrap_owner_invitation(&peer);
    let claimant = full_peer();
    let (challenge_id, challenge_bytes) = pairing_challenge(&peer, &invitation, &claimant).await;
    let fingerprint = presence_key_fingerprint(&claimant.device_key);
    let material = pairing_claim_material(
        &claimant,
        peer.identity.node_id(),
        &challenge_bytes,
        &invitation.invitation_id,
        Some(&fingerprint),
    );
    let signature: p256::ecdsa::Signature = claimant.device_key.sign(&material);
    let mut compressed_spki = vec![
        0x30, 0x39, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01, 0x06, 0x08,
        0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07, 0x03, 0x22, 0x00,
    ];
    compressed_spki.extend_from_slice(
        claimant
            .device_key
            .verifying_key()
            .to_encoded_point(true)
            .as_bytes(),
    );
    let (status, body) = send_json(
        &peer,
        Method::POST,
        "/api/v1/pairing/claim",
        json!({
            "invitation": invitation,
            "challenge_id": challenge_id,
            "device_id": claimant.device_id,
            "device_name": "Same Logical Key",
            "platform": "ios",
            "device_public_key_spki": spki_b64(&claimant.device_key),
            "presence_public_key_spki": base64_encode(&compressed_spki),
            "presence_key_signature": base64url_encode(&signature.to_bytes()),
            "challenge_signature": base64url_encode(&signature.to_bytes()),
        }),
    )
    .await;
    assert_eq!(status, StatusCode::UNPROCESSABLE_ENTITY, "{body:?}");
    assert_eq!(body.unwrap()["error"]["code"], "SIGNATURE_INVALID");
}
