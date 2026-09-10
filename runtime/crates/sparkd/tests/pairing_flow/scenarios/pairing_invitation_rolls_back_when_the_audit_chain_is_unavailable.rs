#[tokio::test]
async fn pairing_invitation_rolls_back_when_the_audit_chain_is_unavailable() {
    let peer = full_peer();
    let (invitation, _) = bootstrap_owner_invitation(&peer);
    let (status, _) = run_claim(&peer, &invitation, &peer, "Owner Device", "macos").await;
    assert_eq!(status, StatusCode::CREATED);
    let before: i64 = peer
        .state
        .database
        .as_ref()
        .unwrap()
        .lock()
        .query_row("SELECT COUNT(*) FROM pairing_invitations", [], |row| {
            row.get(0)
        })
        .unwrap();
    peer.state
        .database
        .as_ref()
        .unwrap()
        .lock()
        .execute("DROP TABLE audit_records", [])
        .unwrap();

    let (status, body) = send_json(
        &peer,
        Method::POST,
        "/api/v1/pairing/invitations",
        json!({ "role": "user", "expires_in_seconds": 300 }),
    )
    .await;
    assert_eq!(status, StatusCode::SERVICE_UNAVAILABLE);
    assert_eq!(body.unwrap()["error"]["code"], "AUDIT_UNAVAILABLE");
    let after: i64 = peer
        .state
        .database
        .as_ref()
        .unwrap()
        .lock()
        .query_row("SELECT COUNT(*) FROM pairing_invitations", [], |row| {
            row.get(0)
        })
        .unwrap();
    assert_eq!(after, before, "the unaudited invitation must roll back");
}
