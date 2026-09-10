#[tokio::test]
async fn legacy_device_can_enroll_presence_key_once_and_then_revoke() {
    let peer = full_peer();
    let (invitation, _) = bootstrap_owner_invitation(&peer);
    let (status, _) =
        run_claim_with_presence_key(&peer, &invitation, &peer, "Legacy Owner", "macos", false)
            .await;
    assert_eq!(status, StatusCode::CREATED);

    let wrong_key = fresh_device_key();
    let response = router(peer.state.clone())
        .oneshot(signed_presence_enrollment(
            &peer,
            &peer.presence_key,
            &wrong_key,
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::FORBIDDEN);
    let stored: Option<Vec<u8>> = peer
        .state
        .database
        .as_ref()
        .unwrap()
        .lock()
        .query_row(
            "SELECT presence_public_key_spki FROM devices WHERE id = ?1",
            rusqlite::params![peer.device_id.to_string()],
            |row| row.get(0),
        )
        .unwrap();
    assert!(stored.is_none());

    let idempotency_key = uuid::Uuid::new_v4().to_string();
    for expected_status in [StatusCode::OK, StatusCode::OK] {
        let mut request = signed_presence_enrollment(&peer, &peer.presence_key, &peer.presence_key);
        request.headers_mut().insert(
            "idempotency-key",
            HeaderValue::from_str(&idempotency_key).unwrap(),
        );
        let response = router(peer.state.clone()).oneshot(request).await.unwrap();
        assert_eq!(response.status(), expected_status);
        let bytes = to_bytes(response.into_body(), 1 << 20).await.unwrap();
        let result: spark_contracts::generated::PresenceKeyEnrollmentResult =
            serde_json::from_slice(&bytes).expect("enrolment result matches contract");
        assert_eq!(
            result.presence_key_fingerprint,
            presence_key_fingerprint(&peer.presence_key)
        );
    }

    let replacement = fresh_device_key();
    let response = router(peer.state.clone())
        .oneshot(signed_presence_enrollment(
            &peer,
            &replacement,
            &replacement,
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::CONFLICT);
    let bytes = to_bytes(response.into_body(), 1 << 20).await.unwrap();
    let envelope: Value = serde_json::from_slice(&bytes).unwrap();
    assert_eq!(envelope["error"]["code"], "USER_PRESENCE_KEY_CONFLICT");

    let enrollment_audit = audit_rows(&peer, "device.presence_key.enroll");
    assert_eq!(
        enrollment_audit
            .iter()
            .map(|row| row.3.as_str())
            .collect::<Vec<_>>(),
        ["refused", "accepted", "succeeded", "accepted", "refused"]
    );
    assert_eq!(enrollment_audit[0].0, peer.device_id.to_string());
    assert_eq!(enrollment_audit[0].1, "owner");
    assert_eq!(enrollment_audit[0].2, format!("device/{}", peer.device_id));
    assert_eq!(
        serde_json::from_str::<Value>(&enrollment_audit[0].4).unwrap()["reason_code"],
        "USER_PRESENCE_INVALID"
    );
    assert_eq!(enrollment_audit[1].4, "{}");
    assert_eq!(enrollment_audit[2].4, "{}");
    assert_eq!(
        serde_json::from_str::<Value>(&enrollment_audit[4].4).unwrap()["reason_code"],
        "USER_PRESENCE_KEY_CONFLICT"
    );

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
    let expires_at = (time::OffsetDateTime::now_utc() + time::Duration::seconds(30))
        .format(&time::format_description::well_known::Rfc3339)
        .unwrap();
    let response = router(peer.state.clone())
        .oneshot(signed_request_with_presence(
            &peer,
            Method::DELETE,
            &path,
            &path,
            &[],
            &fresh_nonce(),
            &timestamp,
            &expires_at,
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::NO_CONTENT);
}
