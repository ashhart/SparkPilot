fn idle_policy_state() -> (AppState, TestClient) {
    let (state, client, _) = test_state("owner");
    let recipe = spark_models::recipe::fixture::RecipeFixture::example();
    sparkd::store::upsert_catalogue_model(&state.database.as_ref().unwrap().lock(), &recipe).unwrap();
    let state = state.with_models(Arc::new(sparkd::models::ModelInventory {
        recipes: vec![recipe], allow_unverified_import: false,
    }));
    (state, client)
}

#[tokio::test]
async fn custom_idle_settings_persist_and_legacy_updates_clear_the_override() {
    let (state, client) = idle_policy_state();
    for (policy, seconds) in [("unload_after_30m", Some(2520)), ("keep_ready", None), ("unload_after_30m", None)] {
        let mut body = json!({"model_id":"example/model-32b", "profile_id":"balanced-16k", "idle_policy":policy});
        if let Some(seconds) = seconds { body["idle_timeout_seconds"] = json!(seconds); }
        let (status, operation) = send(state.clone(), signed_request(&client, Method::POST, "/api/v1/settings/model-idle", body, true)).await;
        assert_eq!(status, StatusCode::ACCEPTED, "{operation}");
        let id = operation["id"].as_str().unwrap().parse().unwrap();
        for attempt in 0..200 {
            let row = state.jobs.get(&state.database.as_ref().unwrap().lock(), id).unwrap().unwrap();
            let value = serde_json::to_value(row).unwrap();
            if value["state"] == "succeeded" { break; }
            assert_ne!(value["state"], "failed", "{value}");
            assert!(attempt < 199, "{value}");
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
        let (status, settings) = send(state.clone(), signed_request(&client, Method::GET, "/api/v1/settings", Value::Null, false)).await;
        assert_eq!(status, StatusCode::OK);
        let saved = &settings["model_idle_policies"][0];
        assert_eq!(saved["idle_policy"], policy);
        assert_eq!(saved["idle_timeout_seconds"], seconds.map_or(Value::Null, |s| json!(s)));
        let (_, catalogue) = send(state.clone(), signed_request(&client, Method::GET, "/api/v1/models", Value::Null, false)).await;
        let profile = &catalogue["items"][0]["profiles"][0];
        assert_eq!(profile["idle_policy"], policy, "{catalogue}");
        assert_eq!(profile["supports_custom_idle_timeout"], true);
        assert_eq!(profile["idle_timeout_seconds"], saved["idle_timeout_seconds"]);
    }
}

#[tokio::test]
async fn custom_idle_settings_reject_invalid_durations_and_still_require_presence() {
    let (state, client) = idle_policy_state();
    for (policy, seconds) in [("unload_after_30m", 59), ("unload_after_30m", 604801), ("keep_ready", 60), ("manual_only", 60)] {
        let (status, _) = send(state.clone(), signed_request(&client, Method::POST, "/api/v1/settings/model-idle", json!({"model_id":"example/model-32b", "profile_id":"balanced-16k", "idle_policy":policy, "idle_timeout_seconds":seconds}), true)).await;
        assert!(status.is_client_error());
    }
    let (status, _) = send(state.clone(), signed_request(&client, Method::POST, "/api/v1/settings/model-idle", json!({"model_id":"example/model-32b", "profile_id":"balanced-16k", "idle_policy":"unload_after_30m", "idle_timeout_seconds":2520}), false)).await;
    assert!(status.is_client_error());
    let count: i64 = state.database.as_ref().unwrap().lock().query_row("SELECT COUNT(*) FROM model_idle_policies", [], |row| row.get(0)).unwrap();
    assert_eq!(count, 0);
}
