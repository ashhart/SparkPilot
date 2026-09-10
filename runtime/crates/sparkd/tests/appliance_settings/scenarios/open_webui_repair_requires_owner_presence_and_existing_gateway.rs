#[tokio::test]
async fn open_webui_repair_requires_owner_presence_and_existing_gateway() {
    for (role, presence, configured, expected) in [
        ("user", true, true, StatusCode::FORBIDDEN),
        ("owner", false, true, StatusCode::FORBIDDEN),
        ("owner", true, false, StatusCode::CONFLICT),
    ] {
        let (state, client, observed) = test_state(role);
        if configured {
            seed_repair_gateway(&state, &client, false);
        }
        let (status, body) = send(
            state,
            signed_request(
                &client,
                Method::POST,
                "/api/v1/services/open-webui/repair",
                Value::Null,
                presence,
            ),
        )
        .await;
        assert_eq!(status, expected, "{body}");
        assert!(
            !observed
                .lock()
                .unwrap()
                .iter()
                .any(|kind| kind == "repair_open_webui")
        );
    }
}
