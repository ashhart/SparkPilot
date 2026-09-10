#[tokio::test]
async fn a_device_paired_before_presence_keys_cannot_revoke() {
    let peer = full_peer();
    let (invitation, _) = bootstrap_owner_invitation(&peer);
    let (status, _) =
        run_claim_with_presence_key(&peer, &invitation, &peer, "Legacy Owner", "macos", false)
            .await;
    assert_eq!(status, StatusCode::CREATED);

    let target_id = uuid::Uuid::new_v4();
    let target_key = fresh_device_key();
    let target_spki = spki_der(&target_key);
    sparkd::store::insert_device(
        &peer.state.database.as_ref().unwrap().lock(),
        &target_id,
        "Target Device",
        "ios",
        &target_spki,
        &sha256_hex(&target_spki),
        "user",
    )
    .unwrap();

    let path = format!("/api/v1/devices/{target_id}");
    let timestamp = rfc3339_now();
    let expires_at =
        (time::OffsetDateTime::parse(&timestamp, &time::format_description::well_known::Rfc3339)
            .unwrap()
            + time::Duration::seconds(30))
        .format(&time::format_description::well_known::Rfc3339)
        .unwrap();
    let request = signed_request_with_presence(
        &peer,
        Method::DELETE,
        &path,
        &path,
        &[],
        &fresh_nonce(),
        &timestamp,
        &expires_at,
    );
    let response = router(peer.state.clone()).oneshot(request).await.unwrap();
    assert_eq!(response.status(), StatusCode::FORBIDDEN);
    let bytes = to_bytes(response.into_body(), 1 << 20).await.unwrap();
    let envelope: Value = serde_json::from_slice(&bytes).unwrap();
    assert_eq!(envelope["error"]["code"], "USER_PRESENCE_NOT_REGISTERED");
    let active: i64 = peer
        .state
        .database
        .as_ref()
        .unwrap()
        .lock()
        .query_row(
            "SELECT COUNT(*) FROM devices WHERE id = ?1 AND revoked_at IS NULL",
            rusqlite::params![target_id.to_string()],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(active, 1);
}
