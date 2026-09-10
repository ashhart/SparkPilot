#[tokio::test]
async fn bound_invitation_refuses_substituted_device_id_before_grant() {
    let server = full_peer();
    let owner = full_peer();
    let recipient = full_peer();
    let (owner_invitation, _) = bootstrap_owner_invitation(&server);
    assert_eq!(
        run_claim(&server, &owner_invitation, &owner, "Owner iPhone", "ios")
            .await
            .0,
        StatusCode::CREATED
    );
    let invitation = {
        let connection = server.state.database.as_ref().unwrap().lock();
        pairing::issue_invitation_for_recipient(
            &connection,
            &server.identity,
            &owner.device_id,
            "user".into(),
            Some(300),
            None,
            Some((
                recipient.device_id,
                sha256_hex(&canonical_point(&recipient.device_key)),
            )),
        )
        .unwrap()
        .payload
    };
    let wrong_key = full_peer();
    let (status, body) = send_json(
        &server,
        Method::POST,
        "/api/v1/pairing/challenge",
        json!({
            "invitation_id": invitation.invitation_id,
            "device_public_key_spki": spki_b64(&wrong_key.device_key),
        }),
    )
    .await;
    assert_eq!(status, StatusCode::CONFLICT);
    assert_eq!(body.unwrap()["error"]["code"], "SIGNATURE_INVALID");

    let substituted = TestPeer {
        state: recipient.state.clone(),
        identity: recipient.identity.clone(),
        device_key: recipient.device_key.clone(),
        presence_key: recipient.presence_key.clone(),
        device_id: uuid::Uuid::new_v4(),
    };
    let (status, body) = run_claim(&server, &invitation, &substituted, "Studio Mac", "macos").await;
    assert_eq!(status, StatusCode::CONFLICT);
    assert_eq!(body.unwrap()["error"]["code"], "SIGNATURE_INVALID");
    let connection = server.state.database.as_ref().unwrap().lock();
    let substituted_grants: i64 = connection
        .query_row(
            "SELECT COUNT(*) FROM devices WHERE id = ?1",
            [substituted.device_id.to_string()],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(substituted_grants, 0);
}
