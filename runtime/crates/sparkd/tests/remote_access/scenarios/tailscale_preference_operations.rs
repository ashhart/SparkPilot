struct PreferenceProvisioner {
    current: Mutex<sparkd::remote_overlay_setup::OverlayPreferences>,
    calls: Mutex<usize>,
    fail: bool,
}

impl PreferenceProvisioner {
    fn new(fail: bool) -> Self {
        Self {
            current: Mutex::new(sparkd::remote_overlay_setup::OverlayPreferences {
                provider: "tailscale".into(), enabled: true, accept_dns: false,
            }),
            calls: Mutex::new(0), fail,
        }
    }
}

impl PrivateOverlayProvisioner for PreferenceProvisioner {
    fn prepare(&self) -> Result<OverlaySetup, String> { Err("not part of preference management".into()) }
    fn status(&self) -> Result<OverlaySetup, String> { Ok(OverlaySetup::tailscale()) }
    fn roll_back(&self, _: OverlayRollback) -> Result<OverlayRollbackReport, String> { Err("not part of preference management".into()) }
    fn preferences(&self) -> Result<sparkd::remote_overlay_setup::OverlayPreferences, String> { Ok(self.current.lock().clone()) }
    fn configure(&self, _: uuid::Uuid, change: sparkd::remote_overlay_setup::OverlayPreferenceChange) -> Result<sparkd::remote_overlay_setup::OverlayPreferences, String> {
        *self.calls.lock() += 1;
        if self.fail { return Err("private helper diagnostic must not reach a retained record".into()); }
        let mut current = self.current.lock();
        if let Some(value) = change.enabled { current.enabled = value; }
        if let Some(value) = change.accept_dns { current.accept_dns = value; }
        Ok(current.clone())
    }
}

#[tokio::test]
async fn tailscale_preference_changes_are_durable_replayable_and_read_back() {
    let (base, client, database, _guard) = test_state("owner");
    let provisioner = Arc::new(PreferenceProvisioner::new(false));
    let remote = RemoteAccessService::new(database.clone(), base.events.clone(), base.identity.node_id().to_string())
        .with_private_overlay_provisioner(provisioner.clone());
    let state = base.with_remote(Arc::new(remote));
    let path = "/api/v1/remote/overlay/preferences";
    let key = uuid::Uuid::new_v4();
    let body = json!({"accept_dns":true});
    let (accepted, operation) = send(state.clone(), signed_request_with_options(&client, "POST", path, Some(&body), vec![], key, Some(path))).await;
    assert_eq!(accepted, StatusCode::ACCEPTED, "{operation}");
    let id = operation["id"].as_str().unwrap();
    assert_eq!(wait_for_remote_operation(&database, id), "succeeded");
    let (replayed, same) = send(state.clone(), signed_request_with_options(&client, "POST", path, Some(&body), vec![], key, None)).await;
    assert_eq!(replayed, StatusCode::ACCEPTED, "{same}");
    assert_eq!(same["id"], operation["id"]);
    assert_eq!(*provisioner.calls.lock(), 1);
    let (status, prefs) = send(state, signed_request(&client, "GET", path, None, vec![])).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(prefs, json!({"provider":"tailscale","enabled":true,"accept_dns":true}));
}

#[tokio::test]
async fn tailscale_preference_failure_is_not_a_false_success_or_secret_disclosure() {
    let (base, client, database, _guard) = test_state("owner");
    let provisioner = Arc::new(PreferenceProvisioner::new(true));
    let remote = RemoteAccessService::new(database.clone(), base.events.clone(), base.identity.node_id().to_string())
        .with_private_overlay_provisioner(provisioner.clone());
    let state = base.with_remote(Arc::new(remote));
    let path = "/api/v1/remote/overlay/preferences";
    let (status, operation) = send(state.clone(), signed_request(&client, "POST", path, Some(&json!({"enabled":false})), vec![])).await;
    assert_eq!(status, StatusCode::ACCEPTED);
    assert_eq!(wait_for_remote_operation(&database, operation["id"].as_str().unwrap()), "failed");
    let (_, prefs) = send(state, signed_request(&client, "GET", path, None, vec![])).await;
    assert_eq!(prefs["enabled"], true);
    let code: String = database.lock().query_row("SELECT error_code FROM operations WHERE id = ?1", [operation["id"].as_str().unwrap()], |row| row.get(0)).unwrap();
    assert_eq!(code, "TAILSCALE_CHANGE_FAILED");
}

#[tokio::test]
async fn tailscale_preferences_without_support_are_unavailable_not_disabled() {
    let (state, client, _, _guard) = test_state("owner");
    let (status, body) = send(state, signed_request(&client, "GET", "/api/v1/remote/overlay/preferences", None, vec![])).await;
    assert_eq!(status, StatusCode::SERVICE_UNAVAILABLE);
    assert!(body.get("enabled").is_none());
}
