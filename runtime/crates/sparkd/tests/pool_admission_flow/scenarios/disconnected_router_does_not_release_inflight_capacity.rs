#[tokio::test]
async fn disconnected_router_does_not_release_inflight_capacity() {
    let f = fixture().await;
    let g = configure(&f, &f.router).await;
    f.backend.set_non_stream_delay(Duration::from_millis(250));
    let body = chat(false);
    let r = reserve(&f, &f.router, &reservation(&f, &g, &body)).await;
    let app = router(f.state.clone());
    let req = request(
        &f,
        &f.router,
        "POST",
        &path(&r, "/execute"),
        Some(&body),
        Some(Uuid::new_v4()),
        false,
    );
    let task = tokio::spawn(async move { app.oneshot(req).await.unwrap() });
    tokio::time::sleep(Duration::from_millis(75)).await;
    task.abort();
    assert!(
        f.state
            .engine
            .manager
            .as_ref()
            .unwrap()
            .begin_request()
            .is_err()
    );
    let (s, v) = post(&f, &f.router, &path(&r, "/cancel"), &json!({}), false).await;
    assert_eq!(s, StatusCode::OK);
    assert_eq!(v["state"], "cancel_requested");
    assert!(
        f.state
            .engine
            .manager
            .as_ref()
            .unwrap()
            .begin_request()
            .is_err()
    );
    tokio::time::sleep(Duration::from_millis(300)).await;
    let (_, v) = send(&f, &f.router, "GET", &path(&r, ""), None, None, false).await;
    assert_eq!(v["state"], "cancelled");
    let (ticket, _) = f
        .state
        .engine
        .manager
        .as_ref()
        .unwrap()
        .begin_request()
        .unwrap();
    drop(ticket);
    close(f).await;
}
