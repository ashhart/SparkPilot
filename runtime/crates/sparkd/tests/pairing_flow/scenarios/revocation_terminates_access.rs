#[tokio::test]
async fn revocation_terminates_access() {
    let peer = full_peer();
    let (invitation, _installer) = bootstrap_owner_invitation(&peer);
    let (status, _) = run_claim(&peer, &invitation, &peer, "Owner Device", "macos").await;
    assert_eq!(status, StatusCode::CREATED);

    // Owner may list devices (installer seed + owner = 2 grants).
    let request = signed_request(
        &peer,
        Method::GET,
        "/api/v1/devices",
        &[],
        &fresh_nonce(),
        &rfc3339_now(),
    );
    let response = router(peer.state.clone()).oneshot(request).await.unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    let bytes = to_bytes(response.into_body(), 1 << 20).await.unwrap();
    let devices: Value = serde_json::from_slice(&bytes).unwrap();
    assert_eq!(devices["items"].as_array().unwrap().len(), 2);
    for device in devices["items"].as_array().unwrap() {
        let _: spark_contracts::generated::Device = serde_json::from_value(device.clone())
            .expect("signed device list item matches the OpenAPI contract");
    }

    // Issue a user invitation over the authenticated admin path.
    let body = json!({ "role": "user", "expires_in_seconds": 300 });
    let body_bytes = serde_json::to_vec(&body).unwrap();
    let invitation_idempotency_key = uuid::Uuid::new_v4().to_string();
    let mut request = signed_request(
        &peer,
        Method::POST,
        "/api/v1/pairing/invitations",
        &body_bytes,
        &fresh_nonce(),
        &rfc3339_now(),
    );
    request.headers_mut().insert(
        "idempotency-key",
        HeaderValue::from_str(&invitation_idempotency_key).unwrap(),
    );
    let response = router(peer.state.clone()).oneshot(request).await.unwrap();
    assert_eq!(
        response.status(),
        StatusCode::CREATED,
        "admin issues user invitation"
    );
    let bytes = to_bytes(response.into_body(), 1 << 20).await.unwrap();
    let user_invitation: pairing::InvitationPayload = serde_json::from_slice(&bytes).unwrap();
    let invitation_audit = audit_rows(&peer, "pairing.invitation.created");
    assert_eq!(invitation_audit.len(), 1);
    assert_eq!(invitation_audit[0].0, peer.device_id.to_string());
    assert_eq!(invitation_audit[0].1, "owner");
    assert_eq!(
        invitation_audit[0].2,
        format!("pairing-invitation/{}", user_invitation.invitation_id)
    );
    assert_eq!(invitation_audit[0].3, "succeeded");
    assert_eq!(invitation_audit[0].4, r#"{"role":"user"}"#);
    let mut retry = signed_request(
        &peer,
        Method::POST,
        "/api/v1/pairing/invitations",
        &body_bytes,
        &fresh_nonce(),
        &rfc3339_now(),
    );
    retry.headers_mut().insert(
        "idempotency-key",
        HeaderValue::from_str(&invitation_idempotency_key).unwrap(),
    );
    let response = router(peer.state.clone()).oneshot(retry).await.unwrap();
    assert_eq!(response.status(), StatusCode::CREATED);
    assert_eq!(
        audit_rows(&peer, "pairing.invitation.created").len(),
        1,
        "an exact retry must not append a duplicate audit row"
    );

    // Pair a second device with the user role.
    let user_peer = full_peer();
    let (status, _) = run_claim(&peer, &user_invitation, &user_peer, "User Device", "ipados").await;
    assert_eq!(status, StatusCode::CREATED);

    let path = format!("/api/v1/devices/{}", user_peer.device_id);
    let timestamp = rfc3339_now();
    let expires_at =
        (time::OffsetDateTime::parse(&timestamp, &time::format_description::well_known::Rfc3339)
            .unwrap()
            + time::Duration::seconds(30))
        .format(&time::format_description::well_known::Rfc3339)
        .unwrap();

    let expired_timestamp = (time::OffsetDateTime::now_utc() - time::Duration::seconds(30))
        .format(&time::format_description::well_known::Rfc3339)
        .unwrap();
    let expired_at = (time::OffsetDateTime::parse(
        &expired_timestamp,
        &time::format_description::well_known::Rfc3339,
    )
    .unwrap()
        + time::Duration::seconds(5))
    .format(&time::format_description::well_known::Rfc3339)
    .unwrap();
    let expired = signed_request_with_presence(
        &peer,
        Method::DELETE,
        &path,
        &path,
        &[],
        &fresh_nonce(),
        &expired_timestamp,
        &expired_at,
    );
    let response = router(peer.state.clone()).oneshot(expired).await.unwrap();
    assert_eq!(response.status(), StatusCode::FORBIDDEN);
    let bytes = to_bytes(response.into_body(), 1 << 20).await.unwrap();
    let envelope: Value = serde_json::from_slice(&bytes).unwrap();
    assert_eq!(envelope["error"]["code"], "USER_PRESENCE_EXPIRED");

    // A normal device signature is not a claim of fresh user presence.
    let missing = signed_request(
        &peer,
        Method::DELETE,
        &path,
        &[],
        &fresh_nonce(),
        &timestamp,
    );
    let response = router(peer.state.clone()).oneshot(missing).await.unwrap();
    assert_eq!(response.status(), StatusCode::FORBIDDEN);
    let bytes = to_bytes(response.into_body(), 1 << 20).await.unwrap();
    let envelope: Value = serde_json::from_slice(&bytes).unwrap();
    assert_eq!(envelope["error"]["code"], "USER_PRESENCE_REQUIRED");

    // A valid proof cannot be moved to another device path.
    let wrong_path = signed_request_with_presence(
        &peer,
        Method::DELETE,
        &path,
        "/api/v1/devices/different",
        &[],
        &fresh_nonce(),
        &timestamp,
        &expires_at,
    );
    let response = router(peer.state.clone())
        .oneshot(wrong_path)
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::FORBIDDEN);
    let bytes = to_bytes(response.into_body(), 1 << 20).await.unwrap();
    let envelope: Value = serde_json::from_slice(&bytes).unwrap();
    assert_eq!(envelope["error"]["code"], "USER_PRESENCE_INVALID");

    // The presence key approves the exact authenticated DELETE request.
    let nonce = fresh_nonce();
    let idempotency_key = uuid::Uuid::new_v4().to_string();
    let mut request = signed_request_with_presence(
        &peer,
        Method::DELETE,
        &path,
        &path,
        &[],
        &nonce,
        &timestamp,
        &expires_at,
    );
    let mut replay = signed_request_with_presence(
        &peer,
        Method::DELETE,
        &path,
        &path,
        &[],
        &nonce,
        &timestamp,
        &expires_at,
    );
    request.headers_mut().insert(
        "idempotency-key",
        HeaderValue::from_str(&idempotency_key).unwrap(),
    );
    replay.headers_mut().insert(
        "idempotency-key",
        HeaderValue::from_str(&idempotency_key).unwrap(),
    );
    let response = router(peer.state.clone()).oneshot(request).await.unwrap();
    assert_eq!(response.status(), StatusCode::NO_CONTENT, "device revoked");
    let response = router(peer.state.clone()).oneshot(replay).await.unwrap();
    assert_eq!(response.status(), StatusCode::CONFLICT);
    let bytes = to_bytes(response.into_body(), 1 << 20).await.unwrap();
    let envelope: Value = serde_json::from_slice(&bytes).unwrap();
    assert_eq!(envelope["error"]["code"], "REQUEST_REPLAYED");

    let audit: (String, String, String, String, String) = peer
        .state
        .database
        .as_ref()
        .expect("db")
        .lock()
        .query_row(
            "SELECT actor_device_id, actor_role, action, resource, result
               FROM audit_records
              WHERE action = 'device.revoke' AND result = 'succeeded'",
            [],
            |row| {
                Ok((
                    row.get(0)?,
                    row.get(1)?,
                    row.get(2)?,
                    row.get(3)?,
                    row.get(4)?,
                ))
            },
        )
        .expect("revocation audit");
    assert_eq!(audit.0, peer.device_id.to_string());
    assert_eq!(audit.1, "owner");
    assert_eq!(audit.2, "device.revoke");
    assert_eq!(audit.3, format!("device/{}", user_peer.device_id));
    assert_eq!(audit.4, "succeeded");

    let audit_results: Vec<(String, String)> = {
        let connection = peer.state.database.as_ref().expect("db").lock();
        let mut statement = connection
            .prepare(
                "SELECT result, details_json
                   FROM audit_records
                  WHERE action = 'device.revoke'
                  ORDER BY sequence",
            )
            .unwrap();
        statement
            .query_map([], |row| Ok((row.get(0)?, row.get(1)?)))
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap()
    };
    assert_eq!(audit_results.len(), 4);
    assert_eq!(audit_results[0].0, "refused");
    assert_eq!(
        serde_json::from_str::<Value>(&audit_results[0].1).unwrap()["reason_code"],
        "USER_PRESENCE_EXPIRED"
    );
    assert_eq!(audit_results[1].0, "refused");
    assert_eq!(
        serde_json::from_str::<Value>(&audit_results[1].1).unwrap()["reason_code"],
        "USER_PRESENCE_REQUIRED"
    );
    assert_eq!(audit_results[2].0, "refused");
    assert_eq!(
        serde_json::from_str::<Value>(&audit_results[2].1).unwrap()["reason_code"],
        "USER_PRESENCE_INVALID"
    );
    assert_eq!(audit_results[3], ("succeeded".into(), "{}".into()));

    let retry_timestamp = rfc3339_now();
    let retry_expires_at = (time::OffsetDateTime::now_utc() + time::Duration::seconds(30))
        .format(&time::format_description::well_known::Rfc3339)
        .unwrap();
    let mut idempotent_retry = signed_request_with_presence(
        &peer,
        Method::DELETE,
        &path,
        &path,
        &[],
        &fresh_nonce(),
        &retry_timestamp,
        &retry_expires_at,
    );
    idempotent_retry.headers_mut().insert(
        "idempotency-key",
        HeaderValue::from_str(&idempotency_key).unwrap(),
    );
    let response = router(peer.state.clone())
        .oneshot(idempotent_retry)
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::NO_CONTENT);
    assert_eq!(
        audit_rows(&peer, "device.revoke").len(),
        4,
        "an exact retry must not append a duplicate audit row"
    );

    let response = router(peer.state.clone())
        .oneshot(signed_request(
            &peer,
            Method::GET,
            "/api/v1/devices",
            &[],
            &fresh_nonce(),
            &rfc3339_now(),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    let bytes = to_bytes(response.into_body(), 1 << 20).await.unwrap();
    let devices: Value = serde_json::from_slice(&bytes).unwrap();
    let revoked = devices["items"]
        .as_array()
        .unwrap()
        .iter()
        .find(|device| device["id"] == user_peer.device_id.to_string())
        .expect("revoked device remains visible for access review");
    let revoked: spark_contracts::generated::Device =
        serde_json::from_value(revoked.clone()).expect("revoked item matches Device contract");
    assert!(revoked.revoked);

    // The revoked device can no longer reach protected endpoints.
    let request = signed_request(
        &user_peer,
        Method::GET,
        "/api/v1/identity",
        &[],
        &fresh_nonce(),
        &rfc3339_now(),
    );
    let response = router(peer.state.clone()).oneshot(request).await.unwrap();
    assert_eq!(
        response.status(),
        StatusCode::UNAUTHORIZED,
        "revoked device blocked"
    );
    let bytes = to_bytes(response.into_body(), 1 << 20).await.unwrap();
    let envelope: Value = serde_json::from_slice(&bytes).unwrap();
    assert_eq!(envelope["error"]["code"], "DEVICE_NOT_PAIRED");

    // §15.8: the revocation is announced to administrators alongside its audit record.
    let announced: Vec<String> = {
        let connection = peer.state.database.as_ref().expect("db").lock();
        let mut statement = connection
            .prepare(
                "SELECT payload_json FROM events
                  WHERE event_type = 'device.revoked' ORDER BY sequence",
            )
            .unwrap();
        statement
            .query_map([], |row| row.get(0))
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap()
    };
    assert_eq!(announced.len(), 1, "one revocation, one announcement");
    let payload: Value = serde_json::from_str(&announced[0]).unwrap();
    assert_eq!(payload["device_id"], user_peer.device_id.to_string());
}
