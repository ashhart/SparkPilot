#[tokio::test]
async fn remote_status_is_disabled_by_default() {
    let (state, client, _, _guard) = test_state("owner");
    let (status, value) = send(
        state.clone(),
        signed_request(&client, "GET", "/api/v1/remote", None, vec![]),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(value["enabled"], false);
    assert_eq!(value["mode"], "disabled");
    assert_eq!(value["health"], "disabled");
    assert_eq!(value["available_modes"], json!(["private_overlay"]));
    assert_eq!(value["private_overlay_provider"], "tailscale");
}
