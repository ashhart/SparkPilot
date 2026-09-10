#[tokio::test]
async fn warmup_due_memory_change_skips_and_never_retries() {
    let p = peer("owner");
    schedule(&p).await;
    p.available.store(1, Ordering::Relaxed);
    p.clock.advance(time::Duration::minutes(10));
    sparkd::warmup::run_due(&p.state).await.unwrap();
    let row = rows(&p).await[0].clone();
    assert_eq!(row["state"], "skipped");
    assert_eq!(row["result_code"], "MODEL_INSUFFICIENT_MEMORY");
    assert!(!p.backend.preparation_started());
    p.available.store(240 << 30, Ordering::Relaxed);
    sparkd::warmup::run_due(&p.state).await.unwrap();
    assert!(!p.backend.preparation_started());
}
