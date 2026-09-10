#[tokio::test]
async fn administrator_cannot_escalate_or_revoke_owner_before_presence_prompt() {
    let peer = full_peer();
    let (owner_invitation, _) = bootstrap_owner_invitation(&peer);
    let (status, _) = run_claim(&peer, &owner_invitation, &peer, "Owner Device", "macos").await;
    assert_eq!(status, StatusCode::CREATED);

    let body = json!({ "role": "administrator", "expires_in_seconds": 300 });
    let body_bytes = serde_json::to_vec(&body).unwrap();
    let timestamp = rfc3339_now();
    let expires_at =
        (time::OffsetDateTime::parse(&timestamp, &time::format_description::well_known::Rfc3339)
            .unwrap()
            + time::Duration::seconds(30))
        .format(&time::format_description::well_known::Rfc3339)
        .unwrap();
    let response = router(peer.state.clone())
        .oneshot(signed_request_with_presence(
            &peer,
            Method::POST,
            "/api/v1/pairing/invitations",
            "/api/v1/pairing/invitations",
            &body_bytes,
            &fresh_nonce(),
            &timestamp,
            &expires_at,
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::CREATED);
    let bytes = to_bytes(response.into_body(), 1 << 20).await.unwrap();
    let invitation: pairing::InvitationPayload = serde_json::from_slice(&bytes).unwrap();
    let administrator = full_peer();
    let (status, _) = run_claim(
        &peer,
        &invitation,
        &administrator,
        "Administrator Device",
        "ios",
    )
    .await;
    assert_eq!(status, StatusCode::CREATED);

    let invitations_before: i64 = peer
        .state
        .database
        .as_ref()
        .unwrap()
        .lock()
        .query_row("SELECT COUNT(*) FROM pairing_invitations", [], |row| {
            row.get(0)
        })
        .unwrap();
    let invitation_body = serde_json::to_vec(&json!({
        "role": "administrator",
        "expires_in_seconds": 300,
    }))
    .unwrap();
    let invitation_path = "/api/v1/pairing/invitations";
    let response = router(peer.state.clone())
        .oneshot(signed_request(
            &administrator,
            Method::POST,
            invitation_path,
            &invitation_body,
            &fresh_nonce(),
            &rfc3339_now(),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::FORBIDDEN);
    let bytes = to_bytes(response.into_body(), 1 << 20).await.unwrap();
    let envelope: Value = serde_json::from_slice(&bytes).unwrap();
    assert_eq!(envelope["error"]["code"], "ROLE_FORBIDDEN");
    let (invitations_after, administrator_replays) = {
        let connection = peer.state.database.as_ref().unwrap().lock();
        let invitations_after: i64 = connection
            .query_row("SELECT COUNT(*) FROM pairing_invitations", [], |row| {
                row.get(0)
            })
            .unwrap();
        let administrator_replays: i64 = connection
            .query_row(
                "SELECT COUNT(*) FROM idempotency_records WHERE device_id = ?1 AND path = ?2",
                rusqlite::params![administrator.device_id.to_string(), invitation_path],
                |row| row.get(0),
            )
            .unwrap();
        (invitations_after, administrator_replays)
    };
    assert_eq!(invitations_after, invitations_before);
    assert_eq!(administrator_replays, 0);
    let invitation_audit = audit_rows(&peer, "pairing.invitation.created");
    let refusal = invitation_audit.last().unwrap();
    assert_eq!(refusal.0, administrator.device_id.to_string());
    assert_eq!(refusal.1, "administrator");
    assert_eq!(refusal.3, "refused");
    assert_eq!(
        serde_json::from_str::<Value>(&refusal.4).unwrap()["reason_code"],
        "ROLE_FORBIDDEN"
    );

    let path = format!("/api/v1/devices/{}", peer.device_id);
    let response = router(peer.state.clone())
        .oneshot(signed_request(
            &administrator,
            Method::DELETE,
            &path,
            &[],
            &fresh_nonce(),
            &rfc3339_now(),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::FORBIDDEN);
    let bytes = to_bytes(response.into_body(), 1 << 20).await.unwrap();
    let envelope: Value = serde_json::from_slice(&bytes).unwrap();
    assert_eq!(envelope["error"]["code"], "ROLE_FORBIDDEN");
    let revocation_audit = audit_rows(&peer, "device.revoke");
    assert_eq!(revocation_audit.len(), 1);
    assert_eq!(revocation_audit[0].0, administrator.device_id.to_string());
    assert_eq!(revocation_audit[0].1, "administrator");
    assert_eq!(revocation_audit[0].2, format!("device/{}", peer.device_id));
    assert_eq!(revocation_audit[0].3, "refused");
    assert_eq!(
        serde_json::from_str::<Value>(&revocation_audit[0].4).unwrap()["reason_code"],
        "ROLE_FORBIDDEN"
    );
}
