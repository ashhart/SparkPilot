#[tokio::test]
async fn one_tap_enable_prepares_tailscale_waits_for_the_owner_sign_in_and_publishes_the_magicdns_route()
 {
    let provisioner = Arc::new(ScriptedProvisioner::signed_out());
    let (state, client, database, _guard) = one_tap_state("owner", provisioner.clone()).await;

    // The review does not block on a signed-out Tailscale; it says the owner will sign in once.
    let (status, preview) = send(
        state.clone(),
        signed_request(
            &client,
            "POST",
            "/api/v1/remote/enable/preview",
            Some(&json!({ "mode": "private_overlay" })),
            vec![],
        ),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{preview}");
    assert_eq!(preview["blockers"], json!([]));
    assert!(
        preview["warnings"]
            .as_array()
            .unwrap()
            .iter()
            .any(|warning| warning["code"] == "TAILSCALE_SETUP_REQUIRED"),
        "{preview}"
    );
    assert_eq!(preview["evidence"]["remote"]["requested_mode_available"], true);
    assert_eq!(preview["evidence"]["remote"]["provider"], "tailscale");
    assert_eq!(
        preview["evidence"]["remote"]["overlay_setup_state"],
        "login_required"
    );

    let mut body = json!({ "mode": "private_overlay" });
    body["accepted_preview_digest"] = preview["preview_digest"].clone();
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

    // The operation parks on the owner's sign-in and the app can read the link meanwhile.
    let stage = wait_for_stage(&database, &operation_id, "awaiting_owner_login");
    assert_eq!(stage, "awaiting_owner_login");
    let (status, setup) = send(
        state.clone(),
        signed_request(&client, "GET", "/api/v1/remote/overlay/setup", None, vec![]),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{setup}");
    assert_eq!(setup["state"], "login_required");
    assert_eq!(
        setup["authorization_url"],
        "https://login.tailscale.com/a/0123456789abcdef"
    );
    let row = state.remote.as_ref().unwrap().status().unwrap();
    assert!(!row.enabled, "remote stays off until the route is verified");

    // The owner signs in; the runtime finishes on its own and publishes the MagicDNS name.
    provisioner.owner_signed_in();
    assert_eq!(wait_for_remote_operation(&database, &operation_id), "succeeded");

    let (status, remote) = send(
        state.clone(),
        signed_request(&client, "GET", "/api/v1/remote", None, vec![]),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{remote}");
    assert_eq!(remote["enabled"], true);
    assert_eq!(remote["mode"], "private_overlay");
    assert_eq!(remote["health"], "healthy");
    assert_eq!(remote["hostname"], "spark-example.tail1234.ts.net");
    assert_eq!(remote["private_overlay_address"], "100.96.4.2");
    assert_eq!(remote["private_overlay_provider"], "tailscale");

    let events: Vec<String> = {
        let conn = database.lock();
        let mut statement = conn
            .prepare(
                "SELECT event_type FROM events WHERE event_type LIKE 'remote.%' ORDER BY sequence",
            )
            .unwrap();
        statement
            .query_map([], |row| row.get(0))
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap()
    };
    assert_eq!(
        events,
        vec![
            "remote.overlay.login_required".to_owned(),
            "remote.tunnel.enabled".to_owned()
        ]
    );
    assert_eq!(provisioner.prepare_calls(), 1);
}
