#[tokio::test]
async fn tailscale_preferences_are_owner_only_and_mutations_require_fresh_presence() {
    let path = "/api/v1/remote/overlay/preferences";
    for role in ["administrator", "developer", "user", "observer"] {
        let (state, client, _, _guard) = test_state(role);
        for method in ["GET", "POST"] {
            let body = (method == "POST").then(|| json!({"accept_dns":true}));
            let (status, _) = send(state.clone(), signed_request(&client, method, path, body.as_ref(), vec![])).await;
            assert_eq!(status, StatusCode::FORBIDDEN, "{role} {method}");
        }
    }
    let (state, client, database, _guard) = test_state("owner");
    let body = json!({"accept_dns":true});
    let (status, result) = send(state.clone(), signed_request_with_options(&client, "POST", path, Some(&body), vec![], uuid::Uuid::new_v4(), None)).await;
    assert_eq!(status, StatusCode::FORBIDDEN, "{result}");
    let count: i64 = database.lock().query_row("SELECT count(*) FROM operations WHERE kind = 'remote.configure'", [], |row| row.get(0)).unwrap();
    assert_eq!(count, 0);
}

#[tokio::test]
async fn tailscale_preferences_reject_empty_combined_and_shell_settings() {
    let (state, client, _, _guard) = test_state("owner");
    for body in [json!({}), json!({"enabled":true,"accept_dns":true}), json!({"enabled":true,"command":"anything"})] {
        let (status, _) = send(state.clone(), signed_request(&client, "POST", "/api/v1/remote/overlay/preferences", Some(&body), vec![])).await;
        assert!(status.is_client_error(), "{body} returned {status}");
        assert_ne!(status, StatusCode::NOT_FOUND);
    }
}
