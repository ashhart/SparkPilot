#[tokio::test]
async fn network_interfaces_are_signed_and_return_per_interface_reachability() {
    let (state, client) = test_state();
    let state = state.with_network_status_provider(Arc::new(StaticNetworkStatus));
    let unsigned = router(state.clone())
        .oneshot(
            Request::builder()
                .uri("/api/v1/network/interfaces")
                .body(axum::body::Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(unsigned.status(), StatusCode::UNAUTHORIZED);

    let (status, body) = get_json(state, &client, "/api/v1/network/interfaces").await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["api_version"], 1);
    assert_eq!(body["interfaces"][0]["name"], "enp1s0");
    assert_eq!(body["interfaces"][0]["link_speed_mbps"], 10_000);
    assert_eq!(body["interfaces"][0]["internet"]["reachable"], true);
    assert!(body["observed_at"].is_string());
}
