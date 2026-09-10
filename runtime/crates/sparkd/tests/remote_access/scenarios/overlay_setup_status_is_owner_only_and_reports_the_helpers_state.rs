#[tokio::test]
async fn overlay_setup_status_is_owner_only_and_reports_the_helpers_state() {
    let provisioner = Arc::new(ScriptedProvisioner::signed_out());
    let (owner_state, owner, _database, _guard) =
        one_tap_state("owner", provisioner.clone()).await;
    let (status, setup) = send(
        owner_state,
        signed_request(&owner, "GET", "/api/v1/remote/overlay/setup", None, vec![]),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{setup}");
    assert_eq!(setup["provider"], "tailscale");
    assert_eq!(setup["state"], "login_required");
    assert!(setup["authorization_url"].is_null(), "no link before prepare ran");

    let (administrator_state, administrator, _database, _guard) =
        one_tap_state("administrator", provisioner).await;
    let (status, refusal) = send(
        administrator_state,
        signed_request(
            &administrator,
            "GET",
            "/api/v1/remote/overlay/setup",
            None,
            vec![],
        ),
    )
    .await;
    assert_eq!(status, StatusCode::FORBIDDEN);
    assert_eq!(refusal["error"]["code"], "ROLE_FORBIDDEN");
}
