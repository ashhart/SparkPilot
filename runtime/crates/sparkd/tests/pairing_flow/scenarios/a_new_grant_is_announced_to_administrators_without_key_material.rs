/// §15.4 step 10: a grant is an event as well as an audit row, and it carries no key material.
#[tokio::test]
async fn a_new_grant_is_announced_to_administrators_without_key_material() {
    let peer = full_peer();
    let (invitation, _installer) = bootstrap_owner_invitation(&peer);
    let (status, _claim) = run_claim(&peer, &invitation, &peer, "Test Device", "macos").await;
    assert_eq!(status, StatusCode::CREATED);

    let rows: Vec<(String, String)> = {
        let connection = peer.state.database.as_ref().expect("db").lock();
        let mut statement = connection
            .prepare(
                "SELECT payload_json, visibility_json FROM events
                  WHERE event_type = 'device.paired' ORDER BY sequence",
            )
            .unwrap();
        statement
            .query_map([], |row| Ok((row.get(0)?, row.get(1)?)))
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap()
    };
    assert_eq!(rows.len(), 1, "one grant, one announcement");
    let payload: serde_json::Value = serde_json::from_str(&rows[0].0).unwrap();
    assert_eq!(payload["device_id"], peer.device_id.to_string());
    assert_eq!(payload["role"], "owner");
    assert_eq!(payload["platform"], "macos");

    let visibility: serde_json::Value = serde_json::from_str(&rows[0].1).unwrap();
    assert_eq!(
        visibility["min_role"], "administrator",
        "a grant announcement is administrative, never public"
    );

    let encoded = rows[0].0.clone();
    assert!(
        !encoded.contains("public_key") && !encoded.contains(&spki_b64(&peer.device_key)),
        "no key material may travel in the announcement: {encoded}"
    );
}
