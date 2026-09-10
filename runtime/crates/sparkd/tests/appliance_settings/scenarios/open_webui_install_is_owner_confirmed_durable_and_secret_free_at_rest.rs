#[tokio::test]
async fn open_webui_install_is_owner_confirmed_durable_and_secret_free_at_rest() {
    let (state, client, observed) = test_state("owner");
    let admin_password = "unique-open-webui-password-42";
    let (status, operation) = send(
        state.clone(),
        signed_request(
            &client,
            Method::POST,
            "/api/v1/services/open-webui/install",
            json!({
                "admin_email": "owner@sparkpilot.local",
                "admin_name": "Spark owner",
                "admin_password": admin_password,
                "accepted_recipe_revision": "2026-08-29.1"
            }),
            true,
        ),
    )
    .await;

    assert_eq!(status, StatusCode::ACCEPTED, "{operation}");
    assert!(!operation.to_string().contains(admin_password));
    wait_for(&observed, "install_open_webui");
    for _ in 0..80 {
        let enabled: i64 = state
            .database
            .as_ref()
            .unwrap()
            .lock()
            .query_row(
                "SELECT COUNT(*) FROM optional_services WHERE service_id = 'open-webui' AND enabled = 1",
                [],
                |row| row.get(0),
            )
            .unwrap();
        if enabled == 1 {
            break;
        }
        std::thread::sleep(Duration::from_millis(25));
    }
    let connection = state.database.as_ref().unwrap().lock();
    let operation_input: String = connection
        .query_row(
            "SELECT input_json FROM operations WHERE kind = 'service.open_webui.install'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    let audit: String = connection
        .query_row(
            "SELECT details_json FROM audit_records WHERE action = 'service.open_webui.install'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert!(!operation_input.contains(admin_password));
    assert!(!audit.contains(admin_password));
    assert!(operation_input.contains("protected_input_supplied"));
    let stored_hash: String = connection
        .query_row(
            "SELECT gateway_token_sha256 FROM optional_services WHERE service_id = 'open-webui'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(stored_hash.len(), 64);
    assert!(!stored_hash.contains(admin_password));
}

#[tokio::test]
async fn existing_webui_restores_its_port_without_claiming_model_gateway_management() {
    let (state, client, observed) = test_state("owner");
    let (status, response) = send(state.clone(), signed_request(
        &client, Method::POST, "/api/v1/services/open-webui/install",
        json!({"port":9090,"adopt_existing":true,"accepted_recipe_revision":"2026-08-29.1"}), true,
    )).await;
    assert_eq!(status, StatusCode::ACCEPTED, "{response}");
    wait_for(&observed, "install_open_webui");
    for _ in 0..80 {
        let (_, service) = send(state.clone(), signed_request(
            &client, Method::GET, "/api/v1/services/open-webui", Value::Null, false,
        )).await;
        if service["healthy"] == true { break; }
        tokio::time::sleep(Duration::from_millis(25)).await;
    }
    state.open_webui_upstream_port.store(0, std::sync::atomic::Ordering::SeqCst);
    sparkd::service_api::restore_open_webui_route(&state).await;
    assert_eq!(state.open_webui_upstream_port.load(std::sync::atomic::Ordering::SeqCst), 9090);
    let (status, service) = send(state, signed_request(
        &client, Method::GET, "/api/v1/services/open-webui", Value::Null, false,
    )).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(service["adopted"], true);
    assert_eq!(service["healthy"], true);
    assert_eq!(service["inference_gateway"]["healthy"], false);
    assert_eq!(service["inference_gateway"]["scopes"], json!([]));
    assert_eq!(service["update_available"], false);
}
