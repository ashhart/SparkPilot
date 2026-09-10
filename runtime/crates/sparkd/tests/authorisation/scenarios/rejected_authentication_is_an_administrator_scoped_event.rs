/// Expose rejected-authentication security events only to administrators and owners.
#[tokio::test]
async fn rejected_authentication_is_an_administrator_scoped_event() {
    let harness = harness();
    let key = fresh_key();
    let device_id = seed_device(&harness.state, &key, "owner");

    // A body that does not match the signed digest.
    let mut request = signed(
        &key,
        &device_id,
        Method::POST,
        "/api/v1/projects",
        br#"{"name":"real"}"#,
        &fresh_nonce(),
    );
    *request.body_mut() = axum::body::Body::from("{\"name\":\"tampered\"}");
    let (status, _) = send(&harness.state, request).await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);

    let conn = harness.state.database.as_ref().unwrap().lock();
    let (event_type, visibility): (String, String) = conn
        .query_row(
            "SELECT event_type, visibility_json FROM events
              WHERE event_type LIKE 'security.%' ORDER BY sequence DESC LIMIT 1",
            [],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .expect("a security event was recorded");
    assert_eq!(event_type, "security.signature.rejected");
    assert!(
        visibility.contains("administrator"),
        "security events are administrator-scoped: {visibility}"
    );

    let developer = sparkd::events::Viewer::new(
        uuid::Uuid::new_v4(),
        sparkd::capability::Role::Developer,
        Default::default(),
    );
    assert!(
        !developer.can_see(&sparkd::events::Visibility::min_role(
            sparkd::capability::Role::Administrator
        )),
        "a developer must not see administrator security events"
    );
}
