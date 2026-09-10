/// BH-29: a timed-out enable used to leave tailscaled enabled and the Spark able to join later.
#[tokio::test]
async fn a_timed_out_enable_undoes_the_tailscale_setup_it_started() {
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

    let undone = provisioner.rollbacks();
    assert_eq!(undone.len(), 1, "the failed enable undid nothing");
    assert!(
        undone[0].logout,
        "the Spark was left able to finish the sign-in"
    );
    assert!(
        undone[0].disable_service,
        "tailscaled was left enabled across reboot"
    );
    let error_code: String = database
        .lock()
        .query_row(
            "SELECT error_code FROM operations WHERE id = ?1",
            [&operation_id],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(
        error_code, "PRIVATE_OVERLAY_LOGIN_TIMEOUT",
        "a clean rollback keeps the original reason"
    );
    let rolled_back: i64 = database
        .lock()
        .query_row(
            "SELECT COUNT(*) FROM events WHERE event_type = 'remote.overlay.rolled_back'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(rolled_back, 1, "the rollback was not published");
    let row = state.remote.as_ref().unwrap().status().unwrap();
    assert!(!row.enabled);
    assert_eq!(row.mode, "disabled");
}

/// BH-29: when the rollback itself fails, the owner is told exactly what is still in place.
#[tokio::test]
async fn a_rollback_that_cannot_finish_names_what_is_still_in_place() {
    let provisioner = Arc::new(ScriptedProvisioner::signed_out_and_stuck());
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
    assert_eq!(error_code, "PRIVATE_OVERLAY_ROLLBACK_INCOMPLETE");
    let remaining: String = database
        .lock()
        .query_row(
            "SELECT json_extract(payload_json, '$.remaining') FROM events
              WHERE event_type = 'remote.overlay.rollback_failed'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert!(
        remaining.contains("still signed in"),
        "the owner was not told what remains: {remaining}"
    );
}
