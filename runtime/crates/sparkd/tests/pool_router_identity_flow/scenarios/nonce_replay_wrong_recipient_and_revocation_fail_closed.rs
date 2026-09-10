#[tokio::test]
async fn nonce_replay_wrong_recipient_and_revocation_fail_closed() {
    let source = node().await;
    let destination = node().await;
    let receipt = enroll(&source, &destination).await;
    let (id, key) = private_test_key(&source);
    let path = format!("{BASE}/pools");
    let headers = sign_headers(
        &destination.state,
        id,
        &key,
        ("GET", &path),
        &[],
        None,
        None,
    );
    let url = format!("https://localhost:{}{path}", destination.address.port());
    let response = destination
        .client
        .get(&url)
        .headers(headers.clone())
        .send()
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    let response = destination
        .client
        .get(&url)
        .headers(headers.clone())
        .send()
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::CONFLICT);
    // Reopen the on-disk registry/nonce store in a fresh router state.
    let reopened =
        rusqlite::Connection::open(destination.state.config.data_dir.join("state.sqlite")).unwrap();
    let mut restarted = destination
        .state
        .clone()
        .with_database(Arc::new(parking_lot::Mutex::new(reopened)));
    restarted.pools = Arc::new(sparkd::pool::PoolService::default());
    let mut replay = axum::http::Request::builder()
        .uri(&path)
        .body(axum::body::Body::empty())
        .unwrap();
    *replay.headers_mut() = headers;
    let response = router(restarted).oneshot(replay).await.unwrap();
    assert_eq!(response.status(), StatusCode::CONFLICT);
    let wrong = sign_headers(&source.state, id, &key, ("GET", &path), &[], None, None);
    assert_eq!(
        destination
            .client
            .get(&url)
            .headers(wrong)
            .send()
            .await
            .unwrap()
            .status(),
        StatusCode::UNAUTHORIZED
    );
    let revoke = format!(
        "{BASE}/router-principals/{}/revoke",
        receipt["principal_id"].as_str().unwrap()
    );
    assert_eq!(
        destination.post(&revoke, &json!({}), false).await.0,
        StatusCode::FORBIDDEN
    );
    assert_eq!(
        destination.post(&revoke, &json!({}), true).await.0,
        StatusCode::OK
    );
    assert!(
        transport::request(
            &source.state,
            destination.state.identity.node_id(),
            Method::GET,
            &path,
            axum::body::Bytes::new(),
            None
        )
        .await
        .is_err()
    );
    source.stop().await;
    destination.stop().await;
}
