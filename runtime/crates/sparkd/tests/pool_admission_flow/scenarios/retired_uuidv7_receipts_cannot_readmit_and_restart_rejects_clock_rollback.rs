#[tokio::test]
async fn retired_uuidv7_receipts_cannot_readmit_and_restart_rejects_clock_rollback() {
    let mut f = fixture().await;
    let g = configure(&f, &f.router).await;
    let value = reservation(&f, &g, &chat(false));
    let r = reserve(&f, &f.router, &value).await;
    let (s, v) = post(&f, &f.router, &path(&r, "/execute"), &chat(false), false).await;
    assert_eq!(s, StatusCode::OK, "{v}");
    tokio::time::sleep(Duration::from_millis(20)).await;
    f.clock.advance(time::Duration::seconds(121));
    let (s, known) = post(
        &f,
        &f.router,
        &format!("{ROOT}/reservations"),
        &value,
        false,
    )
    .await;
    assert_eq!(s, StatusCode::CREATED, "{known}");
    assert_eq!(known["reservation_id"], r["reservation_id"]);
    assert_eq!(known["state"], "succeeded");
    f.clock.advance(time::Duration::seconds(480));
    f.state.pools.prepare(&f.state).unwrap();
    let count: u32 = f
        .state
        .database
        .as_ref()
        .unwrap()
        .lock()
        .query_row("SELECT count(*) FROM inference_reservations", [], |r| {
            r.get(0)
        })
        .unwrap();
    assert_eq!(count, 0);
    let (s, v) = post(
        &f,
        &f.router,
        &format!("{ROOT}/reservations"),
        &value,
        false,
    )
    .await;
    assert_eq!(s, StatusCode::CONFLICT, "{v}");
    assert_eq!(v["error"]["code"], "POOL_REQUEST_ID_EXPIRED");
    f.state.pools = Arc::new(PoolService::default());
    f.clock.advance(time::Duration::milliseconds(-1));
    let (s, v) = post(
        &f,
        &f.router,
        &format!("{ROOT}/reservations"),
        &value,
        false,
    )
    .await;
    assert_eq!(s, StatusCode::CONFLICT, "{v}");
    assert_eq!(v["error"]["code"], "POOL_CLOCK_REGRESSED");
    close(f).await;
}
