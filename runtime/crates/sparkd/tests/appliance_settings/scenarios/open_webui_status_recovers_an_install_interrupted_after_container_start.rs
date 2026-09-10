#[tokio::test]
async fn open_webui_status_recovers_an_install_interrupted_after_container_start() {
    let (state, client, observed) = test_state("owner");
    let (status, operation) = send(
        state.clone(),
        signed_request(
            &client,
            Method::POST,
            "/api/v1/services/open-webui/install",
            json!({
                "admin_email": "owner@sparkpilot.local",
                "admin_name": "Spark owner",
                "admin_password": "unique-open-webui-password-42",
                "accepted_recipe_revision": "2026-08-29.1"
            }),
            true,
        ),
    )
    .await;
    assert_eq!(status, StatusCode::ACCEPTED, "{operation}");
    wait_for(&observed, "install_open_webui");
    for _ in 0..80 {
        let changed = state
            .database
            .as_ref()
            .unwrap()
            .lock()
            .execute(
                "UPDATE optional_services SET enabled = 0, pending_install = 1
                  WHERE service_id = 'open-webui' AND enabled = 1",
                [],
            )
            .unwrap();
        if changed == 1 {
            break;
        }
        std::thread::sleep(Duration::from_millis(25));
    }

    let (status, service) = send(
        state.clone(),
        signed_request(
            &client,
            Method::GET,
            "/api/v1/services/open-webui",
            Value::Null,
            false,
        ),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{service}");
    assert_eq!(service["state"], "healthy");
    assert_eq!(service["inference_gateway"]["port"], 18081);
    assert_eq!(service["inference_gateway"]["loopback_only"], true);
    assert_eq!(service["access_port"], 1);
    assert_eq!(service["access_tls"], false);
    let recovered: (bool, bool) = state
        .database
        .as_ref()
        .unwrap()
        .lock()
        .query_row(
            "SELECT enabled, pending_install FROM optional_services WHERE service_id = 'open-webui'",
            [],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .unwrap();
    assert_eq!(recovered, (true, false));
}
