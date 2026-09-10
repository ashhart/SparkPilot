#[tokio::test]
async fn a_sign_in_that_never_completes_fails_the_enable_with_a_timeout_and_keeps_remote_off() {
    let provisioner = Arc::new(ScriptedProvisioner::signed_out());
    let (state, client, database, _guard) = one_tap_state("owner", provisioner.clone()).await;

    let body = preview_enable_body(&state, &client, "private_overlay", None).await;
    let presence = presence_header(&state, &client).await;
    let (status, accepted) = send(
        state.clone(),
        signed_request(
            &client,
            "POST",
            "/api/v1/remote/enable",
            Some(&body),
            presence,
        ),
    )
    .await;
    assert_eq!(status, StatusCode::ACCEPTED, "{accepted}");
    let operation_id = accepted["id"].as_str().unwrap().to_owned();

    assert_eq!(wait_for_remote_operation(&database, &operation_id), "failed");
    let error_code: String = database
        .lock()
        .query_row(
            "SELECT error_code FROM operations WHERE id = ?1",
            [&operation_id],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(error_code, "PRIVATE_OVERLAY_LOGIN_TIMEOUT");
    let row = state.remote.as_ref().unwrap().status().unwrap();
    assert!(!row.enabled);
    assert_eq!(row.mode, "disabled");
    let enabled_events: i64 = database
        .lock()
        .query_row(
            "SELECT COUNT(*) FROM events WHERE event_type = 'remote.tunnel.enabled'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(enabled_events, 0);
}
