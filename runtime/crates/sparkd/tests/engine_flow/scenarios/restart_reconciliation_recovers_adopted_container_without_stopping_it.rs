#[tokio::test]
async fn restart_reconciliation_recovers_adopted_container_without_stopping_it() {
    let (h, addr, key, device_id) = harness(240 << 30).await;
    let client = reqwest::Client::new();
    let operation_id: uuid::Uuid = load_model(&client, addr, &key, &device_id, None).await["id"]
        .as_str()
        .expect("load operation id")
        .parse()
        .expect("load operation uuid");
    let terminal = wait_terminal(&h.state, operation_id, Duration::from_secs(10)).await;
    assert_eq!(terminal["state"], "succeeded", "{terminal}");

    let external_id = "a".repeat(64);
    h.state
        .database
        .as_ref()
        .expect("db")
        .lock()
        .execute(
            "UPDATE inference_instances SET container_id = ?1, metadata_json = '{\"ownership_origin\":\"external_adoption\"}' WHERE state = 'ready'",
            [&external_id],
        )
        .expect("mark exact workload adopted");

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
    let inventory = h.state.models.as_ref().expect("inventory").snapshot();
    let reconciled = restarted
        .reconcile_startup_with_inventory(&inventory)
        .await
        .expect("recover adopted workload");

    assert_eq!(reconciled, 1);
    assert!(
        !h.backend.stop_started(),
        "adopted container must stay running"
    );
    let view = restarted.view().expect("adopted workload recovered");
    assert_eq!(
        view.external_workload_id.as_deref(),
        Some(external_id.as_str())
    );
    assert_eq!(view.state, sparkd::engine::EngineState::Ready);
    let (persisted_instance_id, persisted_state): (String, String) = h
        .state
        .database
        .as_ref()
        .expect("db")
        .lock()
        .query_row(
            "SELECT id, state FROM inference_instances WHERE container_id = ?1",
            [&external_id],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .expect("recovered ownership row");
    assert_eq!(persisted_state, "ready");

    let reserved = restarted
        .begin_relinquish_adopted(&external_id)
        .expect("reserve exact adopted workload");
    assert_eq!(reserved, persisted_instance_id);
    assert!(
        restarted.begin_request().is_err(),
        "no request may start while ownership is being relinquished"
    );
    restarted
        .finish_relinquish_adopted(&external_id)
        .expect("clear only SparkPilot ownership");
    assert!(restarted.view().is_none());
    assert!(
        !h.backend.stop_started(),
        "relinquishing ownership must not stop or remove the external container"
    );
}
