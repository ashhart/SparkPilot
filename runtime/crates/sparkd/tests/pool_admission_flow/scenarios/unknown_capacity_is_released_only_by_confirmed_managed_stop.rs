#[tokio::test]
async fn unknown_capacity_is_released_only_by_confirmed_managed_stop() {
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
    let (_, v) = send(
        &f,
        &f.owner,
        "GET",
        &format!("{ROOT}/node-capabilities"),
        None,
        None,
        false,
    )
    .await;
    assert!(
        v["exclusion_codes"]
            .as_array()
            .unwrap()
            .contains(&json!("POOL_OUTCOME_QUARANTINED"))
    );
    f.backend.fail_next_stop();
    f.state
        .engine
        .manager
        .as_ref()
        .unwrap()
        .guard_stop(true)
        .unwrap();
    tokio::time::timeout(Duration::from_secs(3), async {
        while f
            .state
            .engine
            .manager
            .as_ref()
            .unwrap()
            .view()
            .is_none_or(|v| v.state != EngineState::Failed)
        {
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    })
    .await
    .unwrap();
    let (_, v) = send(&f, &f.router, "GET", &path(&r, ""), None, None, false).await;
    assert_eq!(v["state"], "outcome_unknown");
    assert_eq!(v["capacity_released"], false);
    f.state
        .engine
        .manager
        .as_ref()
        .unwrap()
        .guard_stop(true)
        .unwrap();
    tokio::time::timeout(Duration::from_secs(3), async {
        while f.state.engine.manager.as_ref().unwrap().view().is_some() {
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    })
    .await
    .unwrap();
    let (_, v) = send(&f, &f.router, "GET", &path(&r, ""), None, None, false).await;
    assert_eq!(v["state"], "outcome_unknown");
    assert_eq!(v["capacity_released"], true);
    assert_eq!(v["reason"], "engine_stopped_outcome_unknown");
    close(f).await;
}
