#[tokio::test]
async fn signed_load_replays_after_app_state_restart() {
    let (h, addr, key, device_id) = harness(240 << 30).await;
    let client = reqwest::Client::new();
    let idempotency_key = uuid::Uuid::new_v4().to_string();
    let body = previewed_apply_body(
        &client,
        addr,
        &key,
        &device_id,
        "POST",
        "/api/v1/inference/load",
        Some(json!({ "model_id": "example/model-32b", "profile_id": "balanced-16k" })),
    )
    .await
    .unwrap()
    .unwrap();
    let (first_status, first_body) = signed_json_with_idempotency(
        &client,
        addr,
        &key,
        &device_id,
        "POST",
        "/api/v1/inference/load",
        Some(body.clone()),
        Some(&idempotency_key),
    )
    .await;
    assert_eq!(first_status, reqwest::StatusCode::ACCEPTED, "{first_body}");

    let mut identity = FileIdentityStore::new(h._dir.path().join("identity"))
        .load_or_create("engine-test")
        .expect("reload identity");
    identity.public.node_id = SIGNING_NODE_ID;
    let database = h.state.database.as_ref().expect("db").clone();
    let restarted = AppState::new_with_clock(
        (*h.state.config).clone(),
        identity,
        h.state.telemetry.clone(),
        None,
        h.state.clock.clone(),
    )
    .with_database(database.clone())
    .with_live_models(h.state.models.as_ref().expect("inventory").clone());
    let restarted_manager = Arc::new(EngineManager::new(
        Arc::new(MockVllmBackend::new()),
        restarted.jobs.clone(),
        restarted.events.clone(),
        restarted.identity.node_id().to_string(),
        restarted.telemetry.clone(),
        database,
        h._dir.path().join("models"),
        Duration::from_millis(250),
        None,
    ));
    let restarted = restarted.with_engine(restarted_manager);
    let listener = tokio::net::TcpListener::bind(("127.0.0.1", 0))
        .await
        .expect("bind restarted state");
    let restarted_addr = listener.local_addr().unwrap();
    tokio::spawn(async move {
        axum::serve(listener, router(restarted)).await.unwrap();
    });

    let (replay_status, replay_body) = signed_json_with_idempotency(
        &client,
        restarted_addr,
        &key,
        &device_id,
        "POST",
        "/api/v1/inference/load",
        Some(body),
        Some(&idempotency_key),
    )
    .await;
    assert_eq!(
        replay_status,
        reqwest::StatusCode::ACCEPTED,
        "{replay_body}"
    );
    assert_eq!(replay_body, first_body);
    let operation_count: i64 = h
        .state
        .database
        .as_ref()
        .unwrap()
        .lock()
        .query_row("SELECT COUNT(*) FROM operations", [], |row| row.get(0))
        .unwrap();
    assert_eq!(operation_count, 1);
}
