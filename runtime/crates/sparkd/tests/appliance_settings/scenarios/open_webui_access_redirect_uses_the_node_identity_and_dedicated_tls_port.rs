#[tokio::test]
async fn open_webui_access_redirect_uses_the_node_identity_and_dedicated_tls_port() {
    let (mut state, _, _) = test_state("owner");
    let mut config = (*state.config).clone();
    config.listen = "0.0.0.0:7443".parse().unwrap();
    config.tls = true;
    state.config = Arc::new(config);
    let host = sparkd::bonjour::instance_label(
        &state.config.node_name,
        &sparkd::bonjour::short_node_id(state.identity.node_id()),
    );
    // Without a usable Host the node's advertised name is the only identity to offer.
    let expected = format!("https://{host}.local:7444/");
    let request = Request::builder()
        .uri("/services/open-webui/")
        .body(axum::body::Body::empty())
        .unwrap();
    let response = router(state.clone()).oneshot(request).await.unwrap();
    assert_eq!(response.status(), StatusCode::TEMPORARY_REDIRECT);
    assert_eq!(
        response.headers().get("location").unwrap(),
        expected.as_str()
    );
    // The host the browser reached the API through keeps the certificate identity it already accepted; only the port moves.
    for (host, expected) in [
        ("spark-one.local:7443", "https://spark-one.local:7444/"),
        ("192.168.1.20:7443", "https://192.168.1.20:7444/"),
    ] {
        let request = Request::builder()
            .uri("/services/open-webui/")
            .header("host", host)
            .body(axum::body::Body::empty())
            .unwrap();
        let response = router(state.clone()).oneshot(request).await.unwrap();
        assert_eq!(response.status(), StatusCode::TEMPORARY_REDIRECT);
        assert_eq!(response.headers().get("location").unwrap(), expected, "{host}");
    }
}
