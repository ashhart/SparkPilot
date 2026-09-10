fn seed_budget_guest(h: &Harness, owner: uuid::Uuid) -> (p256::ecdsa::SigningKey, uuid::Uuid) {
    let key = fresh_device_key();
    let guest = uuid::Uuid::new_v4();
    let invitation = uuid::Uuid::new_v4();
    let conn = h.state.database.as_ref().unwrap().lock();
    sparkd::store::insert_device(
        &conn,
        &guest,
        "Family guest",
        "ios",
        &spki_der(&key),
        &guest.to_string(),
        "observer",
    )
    .unwrap();
    conn.execute("INSERT INTO pairing_invitations (id,role,nonce_hash,issued_by_device_id,issued_at,expires_at,signed_payload_json) VALUES (?1,'guest',?2,?3,'2026-01-01T00:00:00Z','2027-01-01T00:00:00Z','{}')", rusqlite::params![invitation.to_string(), invitation.as_bytes().to_vec(), owner.to_string()]).unwrap();
    let policy = sparkd::guest::GuestPolicy {
        state: sparkd::guest::GrantState::Active,
        display_name: "Family guest".into(),
        allowed_models: vec!["example/model-32b".into()],
        allowed_hours: sparkd::guest::WeeklySchedule::everyday(&[sparkd::guest::HourWindow {
            start_minute: 0,
            end_minute: 1440,
        }]),
        time_zone: "Europe/London".into(),
        max_concurrent_requests: 1,
        daily_token_budget: 100,
        expires_at: None,
    };
    sparkd::guest::insert_grant(&conn, &invitation, &owner, &policy, "2026-01-01T00:00:00Z")
        .unwrap();
    sparkd::guest::bind_grant_to_device(&conn, &invitation, &guest, "2026-01-01T00:00:00Z")
        .unwrap();
    sparkd::guest::set_grant_state(
        &conn,
        &guest,
        sparkd::guest::GrantState::Active,
        "2026-01-01T00:00:00Z",
    )
    .unwrap();
    (key, guest)
}

async fn budget_guest_request(
    h: &Harness,
    key: &p256::ecdsa::SigningKey,
    guest: uuid::Uuid,
) -> axum::response::Response {
    use tower::ServiceExt;
    let bytes = serde_json::to_vec(&json!({"model":"example/model-32b","messages":[{"role":"user","content":"hi"}],"stream":true,"max_tokens":1000,"stream_options":{"include_usage":false}})).unwrap();
    let (headers, body) = signed_parts(key, &guest, "POST", "/v1/chat/completions", &bytes);
    let mut request = axum::http::Request::builder()
        .method("POST")
        .uri("/v1/chat/completions");
    for (name, value) in headers {
        request = request.header(name, value);
    }
    router(h.state.clone())
        .oneshot(request.body(axum::body::Body::from(body)).unwrap())
        .await
        .unwrap()
}

#[tokio::test]
async fn audit_guest_stream_disconnect_and_missing_usage_cannot_refund_the_budget() {
    for cancelled in [false, true] {
        let (h, addr, key, owner) = harness(240 << 30).await;
        let load = load_model(&reqwest::Client::new(), addr, &key, &owner, None).await;
        let id = uuid::Uuid::parse_str(load["id"].as_str().unwrap()).unwrap();
        assert_eq!(
            wait_terminal(&h.state, id, Duration::from_secs(10)).await["state"],
            "succeeded"
        );
        let (guest_key, guest) = seed_budget_guest(&h, owner);
        h.backend.set_omit_usage(true);
        let response = budget_guest_request(&h, &guest_key, guest).await;
        assert_eq!(response.status(), axum::http::StatusCode::OK);
        if cancelled {
            drop(response);
        } else {
            let body = axum::body::to_bytes(response.into_body(), 1 << 20)
                .await
                .unwrap();
            assert!(!String::from_utf8_lossy(&body).contains("\"usage\""));
        }
        let charged: i64 = h
            .state
            .database
            .as_ref()
            .unwrap()
            .lock()
            .query_row(
                "SELECT sum(prompt_tokens+completion_tokens) FROM guest_usage WHERE device_id=?1",
                [guest.to_string()],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(charged, 100, "cancelled={cancelled}");
        let refused = budget_guest_request(&h, &guest_key, guest).await;
        assert_eq!(refused.status(), axum::http::StatusCode::TOO_MANY_REQUESTS);
        let body = axum::body::to_bytes(refused.into_body(), 1 << 20)
            .await
            .unwrap();
        assert!(String::from_utf8_lossy(&body).contains("GUEST_BUDGET_EXHAUSTED"));
    }
}
