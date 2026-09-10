/// Record allow and deny decisions in a hash chain that detects tampering.
#[tokio::test]
async fn decisions_are_recorded_in_a_verifiable_chain() {
    let harness = harness();
    let observer_key = fresh_key();
    let observer = seed_device(&harness.state, &observer_key, "observer");
    let owner_key = fresh_key();
    let owner = seed_device(&harness.state, &owner_key, "owner");

    // A denial: an observer holds no device-pairing capability.
    let invitation = br#"{"role":"user","expires_in_seconds":300}"#;
    let (status, body) = send(
        &harness.state,
        signed(
            &observer_key,
            &observer,
            Method::POST,
            "/api/v1/pairing/invitations",
            invitation,
            &fresh_nonce(),
        ),
    )
    .await;
    assert_eq!(status, StatusCode::FORBIDDEN, "{body}");

    // An acceptance: an owner inviting a `user` needs no presence proof.
    let (status, body) = send(
        &harness.state,
        signed(
            &owner_key,
            &owner,
            Method::POST,
            "/api/v1/pairing/invitations",
            invitation,
            &fresh_nonce(),
        ),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED, "{body}");

    let conn = harness.state.database.as_ref().unwrap().lock();
    let rows: Vec<(String, String, Option<String>)> = conn
        .prepare("SELECT action, result, actor_device_id FROM audit_records ORDER BY sequence")
        .unwrap()
        .query_map([], |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)))
        .unwrap()
        .collect::<Result<_, _>>()
        .unwrap();
    assert!(
        rows.iter()
            .any(|(action, result, actor)| action == "device.pair"
                && result == "refused"
                && actor.as_deref() == Some(observer.to_string().as_str())),
        "the denial is recorded: {rows:?}"
    );
    assert!(
        rows.iter()
            .any(|(action, result, actor)| action == "device.pair"
                && result == "accepted"
                && actor.as_deref() == Some(owner.to_string().as_str())),
        "the acceptance is recorded: {rows:?}"
    );
    assert_eq!(sparkd::audit::verify_chain(&conn).unwrap(), None);

    // Tampering is detectable.
    conn.execute(
        "UPDATE audit_records SET result = 'accepted' WHERE result = 'refused'",
        [],
    )
    .unwrap();
    assert!(sparkd::audit::verify_chain(&conn).unwrap().is_some());
}
