#[tokio::test]
async fn restart_reconciliation_stops_a_persisted_engine_before_reporting_unloaded() {
    let (h, addr, key, device_id) = harness(240 << 30).await;
    let client = reqwest::Client::new();
    let operation_id: uuid::Uuid = load_model(&client, addr, &key, &device_id, None).await["id"]
        .as_str()
        .expect("load operation id")
        .parse()
        .expect("load operation uuid");
    let terminal = wait_terminal(&h.state, operation_id, Duration::from_secs(10)).await;
    assert_eq!(terminal["state"], "succeeded", "{terminal}");

    let (count, state): (i64, String) = h
        .state
        .database
        .as_ref()
        .expect("db")
        .lock()
        .query_row(
            "SELECT COUNT(*), state FROM inference_instances WHERE node_id = ?1",
            [h.state.identity.node_id().to_string()],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .expect("persisted inference instance");
    assert_eq!(count, 1);
    assert_eq!(state, "ready");

    let restarted = Arc::new(EngineManager::new(
        h.backend.clone(),
        h.state.jobs.clone(),
        h.state.events.clone(),
        h.state.identity.node_id().to_string(),
        h.state.telemetry.clone(),
        h.state.database.as_ref().expect("db").clone(),
        h._dir.path().join("models"),
        Duration::from_millis(250),
        None,
    ));
    let reconciled = restarted
        .reconcile_startup()
        .await
        .expect("restart reconciliation");
    assert_eq!(reconciled, 1);
    assert!(h.backend.stop_started());
    let persisted_state: String = h
        .state
        .database
        .as_ref()
        .expect("db")
        .lock()
        .query_row(
            "SELECT state FROM inference_instances WHERE node_id = ?1",
            [h.state.identity.node_id().to_string()],
            |row| row.get(0),
        )
        .expect("reconciled inference instance");
    assert_eq!(persisted_state, "stopped");
    assert!(restarted.view().is_none());
}
