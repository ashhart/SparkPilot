#[tokio::test]
async fn authenticated_activity_updates_roster_last_seen_but_failed_auth_does_not() {
    let h = harness();
    let key = fresh_key();
    let device = seed_device(&h.state, &key, "owner");
    let unseen_device = seed_device(&h.state, &fresh_key(), "user");
    let last_seen = || {
        sparkd::store::device_row(&h.state.database.as_ref().unwrap().lock(), &device)
            .unwrap()
            .unwrap()
            .last_seen_at
    };
    assert_eq!(last_seen(), None);
    let mut invalid = signed(
        &key,
        &device,
        Method::GET,
        "/api/v1/status",
        &[],
        &fresh_nonce(),
    );
    invalid.headers_mut().insert(
        auth::HEADER_SIGNATURE,
        HeaderValue::from_static("invalid-signature"),
    );
    assert_eq!(send(&h.state, invalid).await.0, StatusCode::UNAUTHORIZED);
    assert_eq!(
        last_seen(),
        None,
        "unverified activity must not mark a device seen"
    );

    let before = time::OffsetDateTime::now_utc();
    let nonce = fresh_nonce();
    let (status, _) = send(
        &h.state,
        signed(&key, &device, Method::GET, "/api/v1/telemetry", &[], &nonce),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    let seen = last_seen().expect("successful signed telemetry request records last_seen_at");
    let parsed =
        time::OffsetDateTime::parse(&seen, &time::format_description::well_known::Rfc3339).unwrap();
    assert!(parsed >= before && parsed <= time::OffsetDateTime::now_utc());

    let (status, roster) = send(
        &h.state,
        signed(
            &key,
            &device,
            Method::GET,
            "/api/v1/devices",
            &[],
            &fresh_nonce(),
        ),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    let devices = roster["items"].as_array().unwrap();
    assert_eq!(
        devices
            .iter()
            .find(|row| row["id"] == device.to_string())
            .unwrap()["last_seen_at"],
        seen
    );
    assert!(
        devices
            .iter()
            .find(|row| row["id"] == unseen_device.to_string())
            .unwrap()["last_seen_at"]
            .is_null()
    );
    assert_eq!(
        last_seen().as_deref(),
        Some(seen.as_str()),
        "nearby successful requests are coalesced"
    );

    // Replay refusals must not refresh last-seen even after the normal activity-update interval has elapsed.
    let old = "2026-01-01T00:00:00Z";
    h.state
        .database
        .as_ref()
        .unwrap()
        .lock()
        .execute(
            "UPDATE devices SET last_seen_at = ?1 WHERE id = ?2",
            rusqlite::params![old, device.to_string()],
        )
        .unwrap();
    assert_eq!(
        send(
            &h.state,
            signed(&key, &device, Method::GET, "/api/v1/telemetry", &[], &nonce)
        )
        .await
        .0,
        StatusCode::CONFLICT
    );
    assert_eq!(last_seen().as_deref(), Some(old));
    let mut invalid = signed(
        &key,
        &device,
        Method::GET,
        "/api/v1/status",
        &[],
        &fresh_nonce(),
    );
    invalid.headers_mut().insert(
        auth::HEADER_SIGNATURE,
        HeaderValue::from_static("invalid-signature"),
    );
    assert_eq!(send(&h.state, invalid).await.0, StatusCode::UNAUTHORIZED);
    assert_eq!(last_seen().as_deref(), Some(old));
}
