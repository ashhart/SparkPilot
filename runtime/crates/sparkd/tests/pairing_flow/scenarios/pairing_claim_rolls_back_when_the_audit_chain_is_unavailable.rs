#[tokio::test]
async fn pairing_claim_rolls_back_when_the_audit_chain_is_unavailable() {
    let peer = full_peer();
    let (invitation, _) = bootstrap_owner_invitation(&peer);
    peer.state
        .database
        .as_ref()
        .unwrap()
        .lock()
        .execute("DROP TABLE audit_records", [])
        .unwrap();

    let (status, body) = run_claim(&peer, &invitation, &peer, "Owner Device", "ios").await;
    assert_eq!(status, StatusCode::SERVICE_UNAVAILABLE);
    assert_eq!(body.unwrap()["error"]["code"], "AUDIT_UNAVAILABLE");

    let connection = peer.state.database.as_ref().unwrap().lock();
    let owner_count: i64 = connection
        .query_row(
            "SELECT COUNT(*) FROM devices WHERE role = 'owner' AND revoked_at IS NULL",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(owner_count, 0, "the unaudited grant must roll back");
    let consumed_at: Option<String> = connection
        .query_row(
            "SELECT consumed_at FROM pairing_invitations WHERE id = ?1",
            [invitation.invitation_id.to_string()],
            |row| row.get(0),
        )
        .unwrap();
    assert!(consumed_at.is_none(), "the invitation remains recoverable");
}
