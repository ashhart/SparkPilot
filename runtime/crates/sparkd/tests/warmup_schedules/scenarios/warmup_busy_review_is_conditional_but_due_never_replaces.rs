#[tokio::test]
async fn warmup_busy_review_is_conditional_but_due_never_replaces() {
    let p = peer("owner");
    let recipe = p
        .state
        .models
        .as_ref()
        .unwrap()
        .snapshot()
        .recipe(MODEL)
        .unwrap()
        .clone();
    let manager = p.state.engine.manager.as_ref().unwrap();
    let op = p
        .state
        .jobs
        .create(
            &p.state.database.as_ref().unwrap().lock(),
            "model.load",
            p.device,
            Some(MODEL),
            "{}",
        )
        .unwrap();
    manager.spawn_load(op, &recipe, PROFILE, false).unwrap();
    schedule(&p).await;
    p.clock.advance(time::Duration::minutes(10));
    sparkd::warmup::run_due(&p.state).await.unwrap();
    assert_eq!(rows(&p).await[0]["state"], "skipped");
    assert!(!p.backend.stop_started());
}
