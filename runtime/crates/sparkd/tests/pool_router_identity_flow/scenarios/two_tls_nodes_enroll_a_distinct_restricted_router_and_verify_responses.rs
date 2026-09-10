#[tokio::test]
async fn two_tls_nodes_enroll_a_distinct_restricted_router_and_verify_responses() {
    let source = node().await;
    let destination = node().await;
    let receipt = enroll(&source, &destination).await;
    assert_eq!(receipt["kind"], "pool_router");
    {
        let conn = destination.state.database.as_ref().unwrap().lock();
        let devices: u32 = conn
            .query_row("SELECT count(*) FROM devices", [], |r| r.get(0))
            .unwrap();
        assert_eq!(devices, 1);
        let registry: u32 = conn
            .query_row(
                "SELECT count(*) FROM pool_router_principals WHERE revoked=0",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(registry, 1);
    }
    let response = transport::request(
        &source.state,
        destination.state.identity.node_id(),
        Method::GET,
        &format!("{BASE}/pools"),
        axum::body::Bytes::new(),
        None,
    )
    .await
    .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    assert_eq!(response.json().await.unwrap(), json!({"pools":[]}));
    let response = transport::request(
        &source.state,
        destination.state.identity.node_id(),
        Method::GET,
        &format!("{BASE}/node-capabilities"),
        axum::body::Bytes::new(),
        None,
    )
    .await
    .unwrap()
    .json()
    .await
    .unwrap();
    assert_eq!(response["deployments"], json!([]));
    assert_eq!(response["exclusion_codes"], json!(["POOL_GRANT_REQUIRED"]));
    for (method, path) in [
        ("GET", "/api/v1/identity"),
        ("GET", "/api/v1/inference/router-peers"),
        ("GET", "/api/v1/projects"),
        ("POST", "/v1/chat/completions"),
        ("POST", "/api/v1/inference/router-identity"),
        ("POST", "/api/v1/inference/pools/apply"),
    ] {
        let (s, v) = raw_router(&source, &destination, method, path, &json!({})).await;
        assert_eq!(s, StatusCode::FORBIDDEN, "{path}: {v}");
        assert_eq!(v["error"]["code"], "POOL_ROUTER_SCOPE_FORBIDDEN");
    }
    source.stop().await;
    destination.stop().await;
}
