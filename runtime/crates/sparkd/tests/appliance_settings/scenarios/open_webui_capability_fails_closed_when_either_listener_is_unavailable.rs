#[tokio::test]
async fn open_webui_capability_fails_closed_when_either_listener_is_unavailable() {
    let (state, client, _) = test_state("owner");
    let (available_status, available) = send(
        state.clone(),
        signed_request(
            &client,
            Method::GET,
            "/api/v1/capabilities",
            Value::Null,
            false,
        ),
    )
    .await;
    assert_eq!(available_status, StatusCode::OK);
    assert_eq!(available["features"]["open_webui_service"], true);
    assert_eq!(
        available["limits"]["optional_service_inference_gateway_port"],
        18081
    );
    assert_eq!(
        available["limits"]["optional_service_listeners_available"],
        true
    );

    state
        .optional_services_available
        .store(false, std::sync::atomic::Ordering::SeqCst);
    let (unavailable_status, unavailable) = send(
        state,
        signed_request(
            &client,
            Method::GET,
            "/api/v1/capabilities",
            Value::Null,
            false,
        ),
    )
    .await;
    assert_eq!(unavailable_status, StatusCode::OK);
    assert_eq!(unavailable["features"]["open_webui_service"], false);
}
