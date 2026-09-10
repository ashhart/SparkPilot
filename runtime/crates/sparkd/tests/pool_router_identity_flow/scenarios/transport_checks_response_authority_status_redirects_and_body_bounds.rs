#[tokio::test]
async fn transport_checks_response_authority_status_redirects_and_body_bounds() {
    let source = node().await;
    let destination = node().await;
    enroll(&source, &destination).await;
    for mode in 1..=4 {
        destination.response_fault.store(mode, Ordering::SeqCst);
        let before = destination.pool_requests.load(Ordering::SeqCst);
        let result = transport::request(
            &source.state,
            destination.state.identity.node_id(),
            Method::GET,
            &format!("{BASE}/pools"),
            axum::body::Bytes::new(),
            None,
        )
        .await;
        assert!(result.is_err(), "response fault {mode}");
        assert_eq!(
            destination.pool_requests.load(Ordering::SeqCst),
            before + 1,
            "redirect must not be followed"
        );
    }
    destination.response_fault.store(5, Ordering::SeqCst);
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
    assert!(matches!(
        response.json().await,
        Err(sparkd::pool::PoolError::Refused(
            "POOL_ROUTER_RESPONSE_LIMIT"
        ))
    ));
    destination.response_fault.store(6, Ordering::SeqCst);
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
    let mut stream = response.stream();
    let mut bytes = 0;
    let mut failed = false;
    while let Some(chunk) = stream.next().await {
        match chunk {
            Ok(chunk) => {
                assert!(!failed);
                bytes += chunk.len();
            }
            Err(sparkd::pool::PoolError::Refused("POOL_ROUTER_RESPONSE_LIMIT")) => {
                assert!(!failed);
                failed = true;
            }
            Err(other) => panic!("unexpected error: {other}"),
        }
    }
    assert!(failed);
    assert!(bytes <= 8 * 1024 * 1024);
    source.stop().await;
    destination.stop().await;
}
