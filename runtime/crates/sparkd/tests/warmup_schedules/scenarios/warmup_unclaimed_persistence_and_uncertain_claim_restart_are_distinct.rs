#[tokio::test]
async fn warmup_unclaimed_persistence_and_uncertain_claim_restart_are_distinct() {
    let p = peer("owner");
    let row = schedule(&p).await;
    let database = p.state.database.as_ref().unwrap();
    let op = {
        let conn = database.lock();
        let op = p
            .state
            .jobs
            .create(&conn, "model.load", p.device, Some(MODEL), "{}")
            .unwrap();
        conn.execute(
            "UPDATE warmup_schedules SET state='dispatching',operation_id=?1 WHERE id=?2",
            rusqlite::params![op.to_string(), row["id"].as_str().unwrap()],
        )
        .unwrap();
        op
    };
    let task = sparkd::warmup::spawn(p.state.clone());
    tokio::time::sleep(Duration::from_millis(15)).await;
    task.abort();
    assert_eq!(rows(&p).await[0]["state"], "interrupted");
    assert_eq!(rows(&p).await[0]["operation_id"], op.to_string());
    assert!(!p.backend.preparation_started());
    p.clock.advance(time::Duration::minutes(10));
    sparkd::warmup::run_due(&p.state).await.unwrap();
    assert!(!p.backend.preparation_started());
}
