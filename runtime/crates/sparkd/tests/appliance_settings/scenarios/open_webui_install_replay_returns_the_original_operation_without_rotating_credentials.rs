#[tokio::test]
async fn open_webui_install_replay_returns_the_original_operation_without_rotating_credentials() {
    let (state, client, observed) = test_state("owner");
    let body = json!({
        "admin_email": "owner@sparkpilot.local",
        "admin_name": "Spark owner",
        "admin_password": "unique-open-webui-password-42",
        "accepted_recipe_revision": "2026-08-29.1"
    });
    let idempotency_key = uuid::Uuid::new_v4().to_string();
    let request = |client: &TestClient| {
        let mut request = signed_request(
            client,
            Method::POST,
            "/api/v1/services/open-webui/install",
            body.clone(),
            true,
        );
        request.headers_mut().insert(
            "idempotency-key",
            idempotency_key.parse().expect("valid idempotency key"),
        );
        request
    };
    let (first_status, first) = send(state.clone(), request(&client)).await;
    assert_eq!(first_status, StatusCode::ACCEPTED, "{first}");
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
    let original_hash: String = state
        .database
        .as_ref()
        .unwrap()
        .lock()
        .query_row(
            "SELECT gateway_token_sha256 FROM optional_services WHERE service_id = 'open-webui'",
            [],
            |row| row.get(0),
        )
        .unwrap();

    let (replay_status, replay) = send(state.clone(), request(&client)).await;
    assert_eq!(replay_status, StatusCode::ACCEPTED, "{replay}");
    assert_eq!(first["id"], replay["id"]);
    assert_eq!(
        observed
            .lock()
            .unwrap()
            .iter()
            .filter(|kind| kind.as_str() == "install_open_webui")
            .count(),
        1
    );
    let replay_hash: String = state
        .database
        .as_ref()
        .unwrap()
        .lock()
        .query_row(
            "SELECT gateway_token_sha256 FROM optional_services WHERE service_id = 'open-webui'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(original_hash, replay_hash);
}
