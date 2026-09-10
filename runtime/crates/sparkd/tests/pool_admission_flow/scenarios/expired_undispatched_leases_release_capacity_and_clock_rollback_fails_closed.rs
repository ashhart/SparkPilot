#[tokio::test]
async fn expired_undispatched_leases_release_capacity_and_clock_rollback_fails_closed() {
    let f = fixture().await;
    let g = configure(&f, &f.router).await;
    let r = reserve(&f, &f.router, &reservation(&f, &g, &chat(false))).await;
    f.clock.advance(time::Duration::seconds(31));
    let (_, v) = send(&f, &f.router, "GET", &path(&r, ""), None, None, false).await;
    assert_eq!(v["state"], "expired");
    let (ticket, _) = f
        .state
        .engine
        .manager
        .as_ref()
        .unwrap()
        .begin_request()
        .unwrap();
    drop(ticket);
    f.clock.advance(time::Duration::seconds(-1));
    let (s, v) = post(
        &f,
        &f.router,
        &format!("{ROOT}/reservations"),
        &reservation(&f, &g, &chat(false)),
        false,
    )
    .await;
    assert_eq!(s, StatusCode::CONFLICT);
    assert_eq!(v["error"]["code"], "POOL_CLOCK_REGRESSED");
    close(f).await;
}
