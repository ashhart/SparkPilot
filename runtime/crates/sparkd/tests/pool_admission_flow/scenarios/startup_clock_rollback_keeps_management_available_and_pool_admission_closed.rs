#[tokio::test]
async fn startup_clock_rollback_keeps_management_available_and_pool_admission_closed() {
    let mut f = fixture().await;
    let grant = configure(&f, &f.router).await;
    let reservation = reservation(&f, &grant, &chat(false));
    f.clock.advance(time::Duration::seconds(60));
    f.state.pools.prepare(&f.state).unwrap();
    f.clock.advance(time::Duration::seconds(-30));
    f.state.pools = Arc::new(PoolService::default());
    let maintenance = sparkd::pool::spawn_housekeeping(f.state.clone())
        .expect("pool clock faults must not prevent the management listener from starting");
    for path in ["/api/v1/health", "/api/v1/identity"] {
        let (status, value) = send(&f, &f.owner, "GET", path, None, None, false).await;
        assert_eq!(status, StatusCode::OK, "{path}: {value}");
    }
    let (status, value) = post(
        &f,
        &f.router,
        &format!("{ROOT}/reservations"),
        &reservation,
        false,
    )
    .await;
    assert!(!status.is_success());
    assert_eq!(value["error"]["code"], "POOL_CLOCK_REGRESSED");
    let (status, value) = send(
        &f,
        &f.owner,
        "GET",
        &format!("{ROOT}/node-capabilities"),
        None,
        None,
        false,
    )
    .await;
    assert!(!status.is_success());
    assert_eq!(value["error"]["code"], "POOL_CLOCK_REGRESSED");
    f.clock.advance(time::Duration::seconds(31));
    let expected = (f.clock.now().unix_timestamp_nanos() / 1_000_000) as i64;
    tokio::time::timeout(Duration::from_secs(3), async {
        loop {
            let observed: i64 = f
                .state
                .database
                .as_ref()
                .unwrap()
                .lock()
                .query_row(
                    "SELECT observed_at_milliseconds FROM inference_pool_clock WHERE singleton=1",
                    [],
                    |row| row.get(0),
                )
                .unwrap();
            if observed == expected {
                break;
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    })
    .await
    .expect("maintenance retries after clock recovery without pool traffic");
    let (status, value) = post(
        &f,
        &f.router,
        &format!("{ROOT}/reservations"),
        &reservation,
        false,
    )
    .await;
    assert_eq!(status, StatusCode::CREATED, "{value}");
    maintenance.abort();
    let _ = maintenance.await;
    close(f).await;
}
