#[tokio::test]
async fn open_webui_capability_and_status_fail_closed_without_packaged_trust_material() {
    let (state, client, _) = test_state("owner");
    let data_dir = state.config.data_dir.clone();
    let state = state.with_optional_service_recipe_paths(
        data_dir.join("missing-service-recipe.json"),
        data_dir.join("missing-service-root.pub"),
    );
    let (capability_status, capabilities) = send(
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
    assert_eq!(capability_status, StatusCode::OK);
    assert_eq!(capabilities["features"]["open_webui_service"], false);
    assert_eq!(capabilities["features"]["optional_service_recipes"], false);
    let proxy_response = sparkd::service_api::access_proxy_router(state.clone())
        .oneshot(
            Request::builder()
                .uri("/")
                .body(axum::body::Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(proxy_response.status(), StatusCode::SERVICE_UNAVAILABLE);

    let (service_status, error) = send(
        state,
        signed_request(
            &client,
            Method::GET,
            "/api/v1/services/open-webui",
            Value::Null,
            false,
        ),
    )
    .await;
    assert_eq!(service_status, StatusCode::SERVICE_UNAVAILABLE);
    assert_eq!(error["error"]["code"], "SERVICE_RECIPE_UNAVAILABLE");
}
