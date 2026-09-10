#[tokio::test]
async fn export_requires_administrator_authority_and_fresh_presence() {
    for role in ["observer", "user", "developer"] {
        let (state, client, _directory) = test_state(role);
        let (status, refusal) = send(
            state.clone(),
            signed_request(
                &client,
                Method::POST,
                "/api/v1/diagnostics/export",
                export_body(&[]),
                true,
            ),
        )
        .await;
        assert_eq!(status, StatusCode::FORBIDDEN, "{role} exported diagnostics");
        assert_eq!(refusal["error"]["code"], "ROLE_FORBIDDEN");
        assert_no_accepted_export(&state, role);
    }

    let (state, client, _directory) = test_state("owner");
    let (status, refusal) = send(
        state.clone(),
        signed_request(
            &client,
            Method::POST,
            "/api/v1/diagnostics/export",
            export_body(&[]),
            false,
        ),
    )
    .await;
    assert_eq!(status, StatusCode::FORBIDDEN);
    assert_eq!(refusal["error"]["code"], "USER_PRESENCE_REQUIRED");
    assert_no_accepted_export(&state, "owner without presence");

    for role in ["administrator", "owner"] {
        let (state, client, _directory) = test_state(role);
        let bundle = export(state, &client, &[]).await;
        assert_eq!(
            bundle["manifest"]["files"].as_array().unwrap().len(),
            REQUIRED_SECTIONS.len()
        );
    }
}
