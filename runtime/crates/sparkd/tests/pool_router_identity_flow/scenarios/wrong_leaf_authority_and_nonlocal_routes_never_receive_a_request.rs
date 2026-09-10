#[tokio::test]
async fn wrong_leaf_authority_and_nonlocal_routes_never_receive_a_request() {
    let source = node().await;
    let destination = node().await;
    enroll(&source, &destination).await;
    let mut wrong = destination.trust();
    wrong.tls_certificate_sha256 = "0".repeat(64);
    assert!(transport::probe_enrollment(&wrong).await.is_err());
    for endpoint in [
        "http://127.0.0.1:443",
        "https://example.com",
        "https://user:pass@127.0.0.1",
        "https://127.0.0.1/?route=x",
        "https://100.100.0.1",
        "https://[fd7a:115c:a1e0::1]",
    ] {
        let mut trust = destination.trust();
        trust.endpoint = endpoint.into();
        assert!(
            transport::validate_route(&trust).await.is_err(),
            "{endpoint}"
        );
    }
    {
        let conn = source.state.database.as_ref().unwrap().lock();
        let mut trust = destination.trust();
        trust.authority_fingerprint = "f".repeat(64);
        conn.execute(
            "UPDATE pool_router_peers SET trust_json=?1",
            [serde_json::to_string(&trust).unwrap()],
        )
        .unwrap();
    }
    assert!(
        transport::request(
            &source.state,
            destination.state.identity.node_id(),
            Method::GET,
            &format!("{BASE}/pools"),
            axum::body::Bytes::new(),
            None
        )
        .await
        .is_err()
    );
    source.stop().await;
    destination.stop().await;
}
