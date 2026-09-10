#[tokio::test]
async fn warmup_disable_preserves_terminal_history_and_refuses_started_load() {
    let p = peer("owner");
    let row = schedule(&p).await;
    let id = row["id"].as_str().unwrap();
    let path = format!("/api/v1/inference/warmups/{id}/disable");
    p.state
        .database
        .as_ref()
        .unwrap()
        .lock()
        .execute(
            "UPDATE warmup_schedules SET state='succeeded',result_code='WARMUP_READY' WHERE id=?1",
            [id],
        )
        .unwrap();
    let (status, receipt) = call(&p, "POST", &path, None, true, Uuid::new_v4()).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(receipt["state"], "succeeded");
    assert_eq!(receipt["result_code"], "WARMUP_READY");
    let row = schedule(&p).await;
    let id = row["id"].as_str().unwrap();
    let path = format!("/api/v1/inference/warmups/{id}/disable");
    p.backend.set_readiness_blocked(true);
    p.clock.advance(time::Duration::minutes(10));
    sparkd::warmup::run_due(&p.state).await.unwrap();
    p.clock.set(time::OffsetDateTime::now_utc());
    let (status, refusal) = call(&p, "POST", &path, None, true, Uuid::new_v4()).await;
    assert_eq!(status, StatusCode::CONFLICT, "{refusal}");
    assert_eq!(refusal["error"]["code"], "WARMUP_ALREADY_DISPATCHED");
    assert!(!p.backend.stop_started());
    p.backend.set_readiness_blocked(false);
}
