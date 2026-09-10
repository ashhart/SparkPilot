#[tokio::test]
async fn open_webui_status_disables_access_after_an_interrupted_remove() {
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
    state
        .privileged
        .as_ref()
        .unwrap()
        .call(
            spark_privd::protocol::PrivilegedOperation::RemoveOpenWebUi {
                request_id: uuid::Uuid::new_v4(),
                erase_data: false,
            },
        )
        .unwrap();

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
    assert_eq!(service["state"], "not_installed");
    assert_eq!(service["inference_gateway"]["healthy"], false);
    let enabled: bool = state
        .database
        .as_ref()
        .unwrap()
        .lock()
        .query_row(
            "SELECT enabled FROM optional_services WHERE service_id = 'open-webui'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert!(!enabled);
}
