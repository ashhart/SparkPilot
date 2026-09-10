#[tokio::test]
async fn bound_batch_claims_are_independent_idempotent_and_recipient_locked() {
    let server_a = full_peer();
    let server_b = full_peer();
    let owner = full_peer();
    let recipient = full_peer();

    for server in [&server_a, &server_b] {
        let (owner_invitation, _) = bootstrap_owner_invitation(server);
        let (status, _) = run_claim(server, &owner_invitation, &owner, "Owner iPhone", "ios").await;
        assert_eq!(status, StatusCode::CREATED);
    }

    let recipient_fingerprint = sha256_hex(&canonical_point(&recipient.device_key));
    let issue = |server: &TestPeer| {
        let connection = server.state.database.as_ref().unwrap().lock();
        pairing::issue_invitation_for_recipient(
            &connection,
            &server.identity,
            &owner.device_id,
            "administrator".into(),
            Some(300),
            Some("Studio Mac".into()),
            Some((recipient.device_id, recipient_fingerprint.clone())),
        )
        .unwrap()
        .payload
    };
    let invitation_a = issue(&server_a);
    let invitation_b = issue(&server_b);
    assert_eq!(invitation_a.issued_by_device_id, Some(owner.device_id));
    assert_eq!(invitation_a.recipient_device_id, Some(recipient.device_id));
    assert_eq!(
        invitation_a.recipient_public_key_fingerprint.as_deref(),
        Some(recipient_fingerprint.as_str())
    );

    for (server, invitation) in [(&server_a, &invitation_a), (&server_b, &invitation_b)] {
        let (status, body) = run_claim(server, invitation, &recipient, "Studio Mac", "macos").await;
        assert_eq!(status, StatusCode::CREATED);
        assert_eq!(
            body.unwrap()["device"]["id"],
            recipient.device_id.to_string()
        );
        let audits = audit_rows(server, "pairing.invitation.claimed");
        assert_eq!(audits.len(), 2);
        let recipient_audit = audits.last().unwrap();
        assert_eq!(recipient_audit.0, recipient.device_id.to_string());
        assert_eq!(recipient_audit.1, "administrator");
        assert_eq!(recipient_audit.2, format!("device/{}", recipient.device_id));
        assert_eq!(recipient_audit.3, "succeeded");
    }

    // Replay the first node's claim receipt without duplicating its device grant or successful audit record.
    let (status, body) =
        run_claim(&server_a, &invitation_a, &recipient, "Studio Mac", "macos").await;
    assert_eq!(status, StatusCode::CREATED);
    assert_eq!(
        body.unwrap()["device"]["id"],
        recipient.device_id.to_string()
    );
    let grants: i64 = {
        let connection = server_a.state.database.as_ref().unwrap().lock();
        connection
            .query_row(
                "SELECT COUNT(*) FROM devices WHERE id = ?1 AND revoked_at IS NULL",
                [recipient.device_id.to_string()],
                |row| row.get(0),
            )
            .unwrap()
    };
    assert_eq!(grants, 1);
    assert_eq!(audit_rows(&server_a, "pairing.invitation.claimed").len(), 2);

    let substituted_key = full_peer();
    let (status, body) = send_json(
        &server_b,
        Method::POST,
        "/api/v1/pairing/challenge",
        json!({
            "invitation_id": invitation_b.invitation_id,
            "device_public_key_spki": spki_b64(&substituted_key.device_key),
        }),
    )
    .await;
    assert_eq!(status, StatusCode::CONFLICT);
    assert_eq!(body.unwrap()["error"]["code"], "INVITATION_ALREADY_USED");
}
