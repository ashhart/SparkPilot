#[tokio::test]
async fn startup_stop_releases_only_the_persisted_managed_instance() {
    let mut f = fixture().await;
    let g = configure(&f, &f.router).await;
    let r = reserve(&f, &f.router, &reservation(&f, &g, &chat(false))).await;
    f.state
        .database
        .as_ref()
        .unwrap()
        .lock()
        .execute("UPDATE inference_reservations SET state='accepted'", [])
        .unwrap();
    f.state.pools = Arc::new(PoolService::default());
    f.state.pools.prepare(&f.state).unwrap();
    f.backend.set_stop_blocked(true);
    let manager = restarted_engine(&f);
    let reconcile = tokio::spawn(async move { manager.reconcile_startup().await });
    tokio::time::timeout(Duration::from_secs(2), async {
        while !f.backend.stop_started() {
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
    })
    .await
    .unwrap();
    let (_, v) = send(&f, &f.router, "GET", &path(&r, ""), None, None, false).await;
    assert_eq!(v["capacity_released"], false);
    f.backend.set_stop_blocked(false);
    assert!(reconcile.await.unwrap().is_ok());
    let (_, v) = send(&f, &f.router, "GET", &path(&r, ""), None, None, false).await;
    assert_eq!(v["capacity_released"], true);
    assert_eq!(v["state"], "outcome_unknown");
    close(f).await;
}
