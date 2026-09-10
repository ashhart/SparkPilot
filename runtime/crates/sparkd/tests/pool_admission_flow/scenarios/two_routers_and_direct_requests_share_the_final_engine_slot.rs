#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn two_routers_and_direct_requests_share_the_final_engine_slot() {
    let f = fixture().await;
    let g = configure(&f, &f.router).await;
    let g2 = configure(&f, &f.other).await;
    let r1 = reservation(&f, &g, &chat(false));
    let r2 = reservation(&f, &g2, &chat(false));
    let p = format!("{ROOT}/reservations");
    let barrier = Arc::new(tokio::sync::Barrier::new(3));
    let start = |request: Request<Body>| {
        let app = router(f.state.clone());
        let barrier = barrier.clone();
        tokio::spawn(async move {
            barrier.wait().await;
            let response = app.oneshot(request).await.unwrap();
            let status = response.status();
            let bytes = to_bytes(response.into_body(), 2 << 20).await.unwrap();
            (status, serde_json::from_slice::<Value>(&bytes).unwrap())
        })
    };
    let first = start(request(
        &f,
        &f.router,
        "POST",
        &p,
        Some(&r1),
        Some(Uuid::new_v4()),
        false,
    ));
    let second = start(request(
        &f,
        &f.other,
        "POST",
        &p,
        Some(&r2),
        Some(Uuid::new_v4()),
        false,
    ));
    barrier.wait().await;
    let (a, b) = (first.await.unwrap(), second.await.unwrap());
    assert_eq!(
        [a.0, b.0]
            .iter()
            .filter(|s| **s == StatusCode::CREATED)
            .count(),
        1,
        "{a:?} {b:?}"
    );
    assert_eq!(
        [a.0, b.0]
            .iter()
            .filter(|s| **s == StatusCode::CONFLICT)
            .count(),
        1
    );
    assert!(
        f.state
            .engine
            .manager
            .as_ref()
            .unwrap()
            .begin_request()
            .is_err()
    );
    let (d, r) = if a.0 == StatusCode::CREATED {
        (&f.router, a.1)
    } else {
        (&f.other, b.1)
    };
    let (s, v) = post(&f, d, &path(&r, "/cancel"), &json!({}), false).await;
    assert_eq!(s, StatusCode::OK, "{v}");
    assert_eq!(v["state"], "cancelled");
    let (ticket, _) = f
        .state
        .engine
        .manager
        .as_ref()
        .unwrap()
        .begin_request()
        .unwrap();
    let (s, _) = post(&f, &f.router, &p, &reservation(&f, &g, &chat(false)), false).await;
    assert_eq!(s, StatusCode::CONFLICT);
    drop(ticket);
    close(f).await;
}
