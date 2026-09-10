#[tokio::test]
async fn open_webui_install_fails_closed_without_presence() {
    let (state, client, observed) = test_state("owner");
    let (status, error) = send(
        state,
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
            false,
        ),
    )
    .await;

    assert_eq!(status, StatusCode::FORBIDDEN, "{error}");
    assert_eq!(error["error"]["code"], "USER_PRESENCE_REQUIRED");
    assert!(observed.lock().unwrap().is_empty());
}
