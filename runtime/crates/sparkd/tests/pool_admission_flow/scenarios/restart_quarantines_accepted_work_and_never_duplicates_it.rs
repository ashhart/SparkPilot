#[tokio::test]
async fn restart_quarantines_accepted_work_and_never_duplicates_it() {
    let mut f = fixture().await;
    let g = configure(&f, &f.router).await;
    let value = reservation(&f, &g, &chat(false));
    let r = reserve(&f, &f.router, &value).await;
    // Keep accepted durable work charged across daemon death even after its in-process request ticket is lost.
    f.state
        .database
        .as_ref()
        .unwrap()
        .lock()
        .execute("UPDATE inference_reservations SET state='accepted'", [])
        .unwrap();
    f.state.pools = Arc::new(PoolService::default());
    f.state.pools.prepare(&f.state).unwrap();
    let (_, v) = send(&f, &f.router, "GET", &path(&r, ""), None, None, false).await;
    assert_eq!(v["state"], "outcome_unknown");
    f.clock.advance(time::Duration::seconds(31));
    assert!(
        f.state
            .engine
            .manager
            .as_ref()
            .unwrap()
            .begin_request()
            .is_err()
    );
    let mut retry = value.clone();
    retry["attempt_id"] = json!(Uuid::new_v4());
    let (s, v) = post(
        &f,
        &f.router,
        &format!("{ROOT}/reservations"),
        &retry,
        false,
    )
    .await;
    assert_eq!(s, StatusCode::CONFLICT);
    assert_eq!(v["error"]["code"], "POOL_REQUEST_ALREADY_ASSIGNED");
    assert_eq!(
        post(&f, &f.router, &path(&r, "/execute"), &chat(false), false)
            .await
            .0,
        StatusCode::CONFLICT
    );
    close(f).await;
}
