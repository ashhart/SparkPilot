#[tokio::test]
async fn presence_enrollment_rolls_back_when_the_audit_chain_is_unavailable() {
    let peer = full_peer();
    let (invitation, _) = bootstrap_owner_invitation(&peer);
    let (status, _) =
        run_claim_with_presence_key(&peer, &invitation, &peer, "Legacy Owner", "macos", false)
            .await;
    assert_eq!(status, StatusCode::CREATED);
    peer.state
        .database
        .as_ref()
        .unwrap()
        .lock()
        .execute("DROP TABLE audit_records", [])
        .unwrap();

    let response = router(peer.state.clone())
        .oneshot(signed_presence_enrollment(
            &peer,
            &peer.presence_key,
            &peer.presence_key,
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::SERVICE_UNAVAILABLE);
    let bytes = to_bytes(response.into_body(), 1 << 20).await.unwrap();
    let envelope: Value = serde_json::from_slice(&bytes).unwrap();
    assert_eq!(envelope["error"]["code"], "AUDIT_UNAVAILABLE");
    let stored: Option<Vec<u8>> = peer
        .state
        .database
        .as_ref()
        .unwrap()
        .lock()
        .query_row(
            "SELECT presence_public_key_spki FROM devices WHERE id = ?1",
            [peer.device_id.to_string()],
            |row| row.get(0),
        )
        .unwrap();
    assert!(stored.is_none(), "the unaudited enrollment must roll back");
}
