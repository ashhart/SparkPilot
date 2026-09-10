#[tokio::test]
async fn concurrent_identical_signed_requests_admit_exactly_one_nonce() {
    let peer = full_peer();
    let (invitation, _) = bootstrap_owner_invitation(&peer);
    let (status, _) = run_claim(&peer, &invitation, &peer, "Test Device", "macos").await;
    assert_eq!(status, StatusCode::CREATED);

    let nonce = fresh_nonce();
    let timestamp = rfc3339_now();
    let request_a = signed_request(
        &peer,
        Method::GET,
        "/api/v1/identity",
        &[],
        &nonce,
        &timestamp,
    );
    let request_b = signed_request(
        &peer,
        Method::GET,
        "/api/v1/identity",
        &[],
        &nonce,
        &timestamp,
    );
    let barrier = Arc::new(tokio::sync::Barrier::new(3));
    let barrier_a = Arc::clone(&barrier);
    let app_a = router(peer.state.clone());
    let a = tokio::spawn(async move {
        barrier_a.wait().await;
        app_a.oneshot(request_a).await.unwrap().status()
    });
    let barrier_b = Arc::clone(&barrier);
    let app_b = router(peer.state.clone());
    let b = tokio::spawn(async move {
        barrier_b.wait().await;
        app_b.oneshot(request_b).await.unwrap().status()
    });
    barrier.wait().await;
    let mut statuses = vec![a.await.unwrap(), b.await.unwrap()];
    statuses.sort_by_key(|status| status.as_u16());
    assert_eq!(statuses, vec![StatusCode::OK, StatusCode::CONFLICT]);
}
