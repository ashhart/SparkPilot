#[tokio::test]
async fn warmup_disable_rechecks_an_owner_authorized_before_demotion() {
    use axum::{
        Extension,
        extract::{Path, State},
        http::HeaderMap,
    };
    use sparkd::auth::{AccessAuthentication, AuthenticatedRequest, Principal};
    use sparkd::idempotency::IdempotencyRequest;
    let p = peer("owner");
    let scheduled = schedule(&p).await;
    let id = Uuid::parse_str(scheduled["id"].as_str().unwrap()).unwrap();
    let path = format!("/api/v1/inference/warmups/{id}/disable");
    // Demote the owner after middleware authentication but before handler mutation to reproduce the lock-wait authority race.
    let principal = Principal {
        device_id: p.device,
        role: "owner".into(),
        access_authentication: AccessAuthentication::DeviceSignature,
        user_presence: None,
    };
    let timestamp = p.clock.now_rfc3339();
    let nonce = Uuid::new_v4().to_string();
    let body_hash = sha256_hex(&[]);
    let node = p.state.identity.node_id();
    let authenticated = AuthenticatedRequest {
        method: "POST".into(),
        path_and_query: path.clone(),
        timestamp: timestamp.clone(),
        nonce: nonce.clone(),
        content_sha256: body_hash.clone(),
        device_id: p.device,
        node_id: node,
    };
    let expires_at = (p.clock.now() + time::Duration::seconds(45))
        .format(&time::format_description::well_known::Rfc3339)
        .unwrap();
    let canonical = spark_contracts::user_presence_canonical(
        "POST",
        &path,
        &timestamp,
        &nonce,
        &body_hash,
        &p.device,
        &expires_at,
        &node,
    );
    let signature: p256::ecdsa::Signature = p.presence.sign(canonical.as_bytes());
    let proof = spark_contracts::UserPresenceHeader {
        version: spark_contracts::USER_PRESENCE_PROOF_VERSION,
        expires_at,
        signature: base64url_encode(&signature.to_bytes()),
    };
    let mut headers = HeaderMap::new();
    headers.insert(
        "x-spark-user-presence",
        base64url_encode(&serde_json::to_vec(&proof).unwrap())
            .parse()
            .unwrap(),
    );
    let key = IdempotencyRequest {
        device_id: p.device,
        method: "POST".into(),
        path,
        key: Uuid::new_v4(),
        body_hash,
        request_id: None,
    };
    {
        let conn = p.state.database.as_ref().unwrap().lock();
        sparkd::store::insert_device(
            &conn,
            &Uuid::new_v4(),
            "remaining owner",
            "macos",
            &[1],
            "remaining-owner",
            "owner",
        )
        .unwrap();
        conn.execute(
            "UPDATE devices SET role='administrator' WHERE id=?1",
            [p.device.to_string()],
        )
        .unwrap();
    }
    let (status, axum::Json(body)) = sparkd::warmup_api::disable_warmup(
        State(p.state.clone()),
        Extension(principal),
        Extension(authenticated),
        Path(id),
        key,
        headers,
    )
    .await
    .unwrap();
    assert_eq!(status, StatusCode::FORBIDDEN, "{body}");
    assert_eq!(body["error"]["code"], "ROLE_FORBIDDEN");
    let conn = p.state.database.as_ref().unwrap().lock();
    let state: String = conn
        .query_row(
            "SELECT state FROM warmup_schedules WHERE id=?1",
            [id.to_string()],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(
        state, "pending",
        "a demoted owner must not cancel the schedule"
    );
}
