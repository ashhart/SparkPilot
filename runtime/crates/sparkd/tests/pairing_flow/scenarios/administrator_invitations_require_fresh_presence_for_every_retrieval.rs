#[tokio::test]
async fn administrator_invitations_require_fresh_presence_for_every_retrieval() {
    let peer = full_peer();
    let (owner_invitation, _) = bootstrap_owner_invitation(&peer);
    let (status, _) = run_claim(&peer, &owner_invitation, &peer, "Owner Device", "macos").await;
    assert_eq!(status, StatusCode::CREATED);

    let body = serde_json::to_vec(&json!({
        "role": "administrator",
        "expires_in_seconds": 300,
    }))
    .unwrap();
    let path = "/api/v1/pairing/invitations";
    let response = router(peer.state.clone())
        .oneshot(signed_request(
            &peer,
            Method::POST,
            path,
            &body,
            &fresh_nonce(),
            &rfc3339_now(),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::FORBIDDEN);
    let bytes = to_bytes(response.into_body(), 1 << 20).await.unwrap();
    let envelope: Value = serde_json::from_slice(&bytes).unwrap();
    assert_eq!(envelope["error"]["code"], "USER_PRESENCE_REQUIRED");

    let timestamp = rfc3339_now();
    let expires_at =
        (time::OffsetDateTime::parse(&timestamp, &time::format_description::well_known::Rfc3339)
            .unwrap()
            + time::Duration::seconds(30))
        .format(&time::format_description::well_known::Rfc3339)
        .unwrap();
    let idempotency_key = uuid::Uuid::new_v4().to_string();
    let mut authorized = signed_request_with_presence(
        &peer,
        Method::POST,
        path,
        path,
        &body,
        &fresh_nonce(),
        &timestamp,
        &expires_at,
    );
    authorized.headers_mut().insert(
        "idempotency-key",
        HeaderValue::from_str(&idempotency_key).unwrap(),
    );
    let response = router(peer.state.clone())
        .oneshot(authorized)
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::CREATED);
    let first_body = to_bytes(response.into_body(), 1 << 20).await.unwrap();

    let mut retry = signed_request(
        &peer,
        Method::POST,
        path,
        &body,
        &fresh_nonce(),
        &rfc3339_now(),
    );
    retry.headers_mut().insert(
        "idempotency-key",
        HeaderValue::from_str(&idempotency_key).unwrap(),
    );
    let response = router(peer.state.clone()).oneshot(retry).await.unwrap();
    assert_eq!(response.status(), StatusCode::FORBIDDEN);
    let bytes = to_bytes(response.into_body(), 1 << 20).await.unwrap();
    let envelope: Value = serde_json::from_slice(&bytes).unwrap();
    assert_eq!(envelope["error"]["code"], "USER_PRESENCE_REQUIRED");

    let timestamp = rfc3339_now();
    let expires_at =
        (time::OffsetDateTime::parse(&timestamp, &time::format_description::well_known::Rfc3339)
            .unwrap()
            + time::Duration::seconds(30))
        .format(&time::format_description::well_known::Rfc3339)
        .unwrap();
    let mut retry = signed_request_with_presence(
        &peer,
        Method::POST,
        path,
        path,
        &body,
        &fresh_nonce(),
        &timestamp,
        &expires_at,
    );
    retry.headers_mut().insert(
        "idempotency-key",
        HeaderValue::from_str(&idempotency_key).unwrap(),
    );
    let response = router(peer.state.clone()).oneshot(retry).await.unwrap();
    assert_eq!(response.status(), StatusCode::CREATED);
    let replay_body = to_bytes(response.into_body(), 1 << 20).await.unwrap();
    assert_eq!(replay_body, first_body);

    let audit = audit_rows(&peer, "pairing.invitation.created");
    assert_eq!(audit.len(), 3, "two refusals and one successful invitation");
    assert_eq!(audit[0].3, "refused");
    assert_eq!(
        serde_json::from_str::<Value>(&audit[0].4).unwrap()["reason_code"],
        "USER_PRESENCE_REQUIRED"
    );
    assert_eq!(audit[1].3, "succeeded");
    assert_eq!(audit[2].3, "refused");
    assert_eq!(
        serde_json::from_str::<Value>(&audit[2].4).unwrap()["reason_code"],
        "USER_PRESENCE_REQUIRED"
    );
}
