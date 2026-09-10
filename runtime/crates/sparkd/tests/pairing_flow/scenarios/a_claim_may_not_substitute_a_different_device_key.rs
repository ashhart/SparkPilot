/// Reject claims signed by a substituted key rather than the exact P-256 key bound to the issued challenge.
#[tokio::test]
async fn a_claim_may_not_substitute_a_different_device_key() {
    let peer = full_peer();
    let (invitation, _) = bootstrap_owner_invitation(&peer);

    // The honest device asks for a challenge.
    let honest = full_peer();
    let (challenge_status, challenge) = send_json(
        &peer,
        Method::POST,
        "/api/v1/pairing/challenge",
        json!({
            "invitation_id": invitation.invitation_id,
            "device_public_key_spki": spki_b64(&honest.device_key),
        }),
    )
    .await;
    assert_eq!(challenge_status, StatusCode::OK);
    let challenge = challenge.expect("challenge body");
    let challenge_id: uuid::Uuid =
        serde_json::from_value(challenge["challenge_id"].clone()).expect("challenge id");
    let challenge_bytes =
        base64url_decode(challenge["challenge"].as_str().expect("challenge")).expect("bytes");

    // An attacker claims it with their own key, signing correctly with it.
    let attacker = full_peer();
    let signature = device_challenge_signature(
        &attacker,
        peer.identity.node_id(),
        &challenge_bytes,
        &invitation.invitation_id,
        None,
    );
    let (status, body) = send_json(
        &peer,
        Method::POST,
        "/api/v1/pairing/claim",
        json!({
            "invitation": invitation,
            "challenge_id": challenge_id,
            "device_id": attacker.device_id,
            "device_name": "Attacker iPhone",
            "platform": "ios",
            "device_public_key_spki": spki_b64(&attacker.device_key),
            "challenge_signature": signature,
        }),
    )
    .await;

    assert_ne!(
        status,
        StatusCode::CREATED,
        "a substituted device key must not be granted a role: {body:?}"
    );

    // And no device was registered for it.
    let conn = peer.state.database.as_ref().expect("db").lock();
    let granted: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM devices WHERE id = ?1",
            rusqlite::params![attacker.device_id.to_string()],
            |row| row.get::<_, i64>(0),
        )
        .expect("count");
    assert_eq!(granted, 0);

    // The node still has no owner, so the honest device can still pair.
    assert!(!sparkd::store::has_owner(&conn).expect("has_owner"));
}
