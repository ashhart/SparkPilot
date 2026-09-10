#[tokio::test]
async fn warmup_pending_survives_restart_but_claim_is_not_replayed() {
    let p = peer("owner");
    let scheduled = schedule(&p).await;
    // A separately opened connection sees the schedule, not just shared state.
    let reopened = rusqlite::Connection::open(p._dir.path().join("state.sqlite")).unwrap();
    let count: i64 = reopened
        .query_row(
            "SELECT COUNT(*) FROM warmup_schedules WHERE state='pending'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(count, 1);

    // New scheduler instance sees the same durable storage, while app is absent.
    let mut restarted = p.state.clone();
    restarted.warmups = Default::default();
    let runner = sparkd::warmup::spawn(restarted.clone());
    tokio::task::yield_now().await;
    p.clock.advance(time::Duration::minutes(10));
    sparkd::warmup::run_due(&restarted).await.unwrap();
    let rows = rows(&p).await;
    assert_eq!(rows[0]["id"], scheduled["id"]);
    assert!(rows[0]["operation_id"].is_string(), "{rows}");
    let id = rows[0]["operation_id"].clone();
    sparkd::warmup::run_due(&restarted).await.unwrap();
    assert_eq!(self::rows(&p).await[0]["operation_id"], id);
    runner.abort();
    let second = sparkd::warmup::spawn(restarted);
    tokio::time::sleep(Duration::from_millis(20)).await;
    second.abort();
    let conn = p.state.database.as_ref().unwrap().lock();
    let count: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM operations WHERE kind='model.load'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(count, 1);
}
