async fn web_setting_terminal(state: &AppState, id: &Value) -> Value {
    let id = uuid::Uuid::parse_str(id.as_str().unwrap()).unwrap();
    for _ in 0..100 {
        let operation = state
            .jobs
            .get(&state.database.as_ref().unwrap().lock(), id)
            .unwrap()
            .unwrap();
        let value = serde_json::to_value(operation).unwrap();
        if matches!(
            value["state"].as_str(),
            Some("succeeded" | "failed" | "cancelled")
        ) {
            return value;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    panic!("search setting operation did not finish")
}

#[tokio::test]
async fn audit_search_setup_failure_does_not_enable_an_unavailable_service() {
    let (mut state, client, _) = test_state("owner");
    state.privileged = None;
    let (status, accepted) = send(state.clone(), signed_request(&client, Method::PUT, "/api/v1/web/settings", json!({
        "policy": "automations_and_chats", "search_backend": "searxng", "searxng_url": "http://127.0.0.1:18119"
    }), true)).await;
    assert_eq!(status, StatusCode::ACCEPTED, "{accepted}");
    let operation = web_setting_terminal(&state, &accepted["id"]).await;
    assert_eq!(operation["state"], "failed");
    assert_eq!(operation["error_code"], "WEB_SEARCH_UNAVAILABLE");
    assert_eq!(
        sparkd::automations_api::web_settings::load(&state).policy,
        sparkd::web_tools::policy::WebAccessPolicy::Off
    );
}

#[tokio::test]
async fn audit_turning_web_access_off_never_needs_a_working_search_installer() {
    let (mut state, client, observed) = test_state("owner");
    state.privileged = None;
    let (status, accepted) = send(state.clone(), signed_request(&client, Method::PUT, "/api/v1/web/settings", json!({
        "policy": "off", "search_backend": "searxng", "searxng_url": "http://127.0.0.1:18119"
    }), true)).await;
    assert_eq!(status, StatusCode::ACCEPTED, "{accepted}");
    assert_eq!(
        web_setting_terminal(&state, &accepted["id"]).await["state"],
        "succeeded"
    );
    assert!(observed.lock().unwrap().is_empty());
}

#[tokio::test]
async fn audit_unchanged_search_settings_can_repair_the_local_service() {
    let (state, client, observed) = test_state("owner");
    let body = json!({"policy":"automations_and_chats","search_backend":"searxng","searxng_url":"http://127.0.0.1:18119"});
    for _ in 0..2 {
        let (status, accepted) = send(
            state.clone(),
            signed_request(
                &client,
                Method::PUT,
                "/api/v1/web/settings",
                body.clone(),
                true,
            ),
        )
        .await;
        assert_eq!(status, StatusCode::ACCEPTED, "{accepted}");
        assert_eq!(
            web_setting_terminal(&state, &accepted["id"]).await["state"],
            "succeeded"
        );
    }
    assert_eq!(
        observed
            .lock()
            .unwrap()
            .iter()
            .filter(|operation| operation.as_str() == "install_searxng")
            .count(),
        2
    );
}

#[tokio::test]
async fn audit_brave_rejects_a_missing_saved_key_before_changing_policy() {
    let (state, client, observed) = test_state("owner");
    let (status, body) = send(state.clone(), signed_request(&client, Method::PUT, "/api/v1/web/settings", json!({
        "policy":"automations_and_chats","search_backend":"brave","brave_credential_id":uuid::Uuid::new_v4()
    }), true)).await;
    assert_eq!(status, StatusCode::BAD_REQUEST, "{body}");
    assert_eq!(body["error"]["code"], "WEB_SEARCH_BACKEND_INCOMPLETE");
    assert!(observed.lock().unwrap().is_empty());
    assert_eq!(
        sparkd::automations_api::web_settings::load(&state).policy,
        sparkd::web_tools::policy::WebAccessPolicy::Off
    );
}
