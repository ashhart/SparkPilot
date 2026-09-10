#[tokio::test(flavor = "multi_thread", worker_threads = 3)]
async fn direct_and_pool_admission_race_atomically_for_one_slot() {
    let f = fixture().await;
    let g = configure(&f, &f.router).await;
    let value = reservation(&f, &g, &chat(false));
    let req = request(
        &f,
        &f.router,
        "POST",
        &format!("{ROOT}/reservations"),
        Some(&value),
        Some(Uuid::new_v4()),
        false,
    );
    let barrier = Arc::new(tokio::sync::Barrier::new(3));
    let start = barrier.clone();
    let engine = f.state.engine.manager.as_ref().unwrap().clone();
    let direct = tokio::spawn(async move {
        start.wait().await;
        engine.begin_request()
    });
    let start = barrier.clone();
    let app = router(f.state.clone());
    let pooled = tokio::spawn(async move {
        start.wait().await;
        app.oneshot(req).await.unwrap()
    });
    barrier.wait().await;
    let direct = direct.await.unwrap();
    let pooled = pooled.await.unwrap();
    assert_eq!(
        usize::from(direct.is_ok()) + usize::from(pooled.status() == StatusCode::CREATED),
        1
    );
    drop(direct);
    drop(pooled);
    close(f).await;
}
