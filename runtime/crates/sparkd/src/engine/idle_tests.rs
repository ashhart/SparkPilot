use super::*;
use crate::engine_backend::MockVllmBackend;
use spark_models::recipe::fixture::RecipeFixture;
use std::cell::Cell;

fn ready_engine() -> (EngineManager, Arc<MockVllmBackend>) {
    let mut db = rusqlite::Connection::open_in_memory().unwrap();
    crate::migration::migrate(&mut db).unwrap();
    let backend = Arc::new(MockVllmBackend::new());
    let manager = EngineManager::new(
        backend.clone(),
        JobService::new(),
        EventBus::new(),
        Uuid::new_v4().to_string(),
        Arc::new(spark_telemetry::FakeSystemMonitor),
        Arc::new(Mutex::new(db)),
        PathBuf::from("/unused-test-models"),
        Duration::ZERO,
        None,
    )
    .with_model_policy(0, Duration::from_secs(30), Duration::ZERO);
    let recipe = RecipeFixture::example();
    let instance = EngineInstance {
        instance_id: Uuid::new_v4(),
        model_id: recipe.id().into(),
        profile_id: recipe.profiles[0].id.clone(),
        served_name: "idle-test".into(),
        model_snapshot: PathBuf::from("/unused-test-models"),
        internal_port: 0,
        api_key: "synthetic-idle-test-key".into(),
        external_workload_id: None,
        profile: recipe.profiles[0].clone(),
        recipe,
        memory_baseline_bytes: 0,
        memory_limit_bytes: None,
        gpu_memory_utilisation_milli: 700,
    };
    let rt = tokio::runtime::Runtime::new().unwrap();
    let port = rt.block_on(backend.launch(&instance)).unwrap();
    let mut core = manager.inner.lock();
    core.instance = Some(EngineInstance {
        internal_port: port,
        ..instance
    });
    core.state = EngineState::Ready;
    drop(core);
    (manager, backend)
}

#[test]
fn active_request_past_idle_deadline_yields_instead_of_spinning() {
    let (manager, _) = ready_engine();
    manager.inner.lock().active_requests = 1;
    let (instance, generation, timeout) = manager.idle().idle_watch_configuration().unwrap();
    let sleeps = Cell::new(0);
    let probes = Cell::new(0);
    manager.idle().idle_watch_with(
        instance,
        generation,
        timeout,
        |delay| {
            assert!(!delay.is_zero());
            assert_eq!(manager.inner.lock().state, EngineState::Ready);
            sleeps.set(sleeps.get() + 1);
            manager.inner.lock().active_requests = 0;
        },
        |_| {
            probes.set(probes.get() + 1);
            assert!(
                probes.get() < 8,
                "idle watchdog busy-spins without sleeping while a request is active"
            );
            timeout
        },
    );
    assert_eq!(sleeps.get(), 1);
    assert_eq!(manager.inner.lock().state, EngineState::Unloaded);
}

#[test]
fn automatic_idle_unload_stops_the_loaded_backend_at_the_deadline() {
    let (manager, backend) = ready_engine();
    let (instance, generation, timeout) = manager.idle().idle_watch_configuration().unwrap();
    let elapsed = Cell::new(Duration::ZERO);
    let before = manager.inner.lock().instance.clone().unwrap();
    manager.idle().idle_watch_with(
        instance,
        generation,
        timeout,
        |delay| {
            assert_eq!(manager.inner.lock().state, EngineState::Ready);
            elapsed.set(elapsed.get() + delay);
        },
        |_| elapsed.get(),
    );
    assert_eq!(elapsed.get(), timeout);
    assert_eq!(manager.inner.lock().state, EngineState::Unloaded);
    assert!(manager.inner.lock().instance.is_none());
    let rt = tokio::runtime::Runtime::new().unwrap();
    assert!(!rt.block_on(backend.is_running(&before)));
    let event: String = manager
        .db
        .lock()
        .query_row(
            "SELECT event_type FROM events WHERE event_type = 'model.idle.unloaded'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(event, "model.idle.unloaded");
}

/// §31.9: a reservation the owner can still execute is durable work, even before it is dispatched.
fn reserve_durable_work(manager: &EngineManager, instance_id: Uuid, state: &str) {
    let conn = manager.db.lock();
    conn.execute(
        "INSERT INTO inference_pool_policies (pool_id, revision, policy_json, owner_device_id, updated_at)
         VALUES ('pool-1', 1, '{}', 'owner-device', 0)",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO inference_router_grants (grant_id, pool_id, grant_json, revoked, expires_at)
         VALUES ('grant-1', 'pool-1', '{}', 0, 9999999999)",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO inference_reservations
            (reservation_id, request_id, request_created_at_milliseconds, attempt_id, grant_id,
             pool_id, router_device_id, caller_device_id, deployment_id, engine_instance_id,
             capacity_released, request_sha256, request_bytes, binding_sha256, policy_revision,
             context_budget, output_budget, state, created_at, expires_at, updated_at)
         VALUES ('res-1', 'req-1', 0, 'attempt-1', 'grant-1', 'pool-1', 'router', 'caller',
                 'deployment', ?1, 0, 'sha', 16, 'binding', 1, 1024, 128, ?2, 0, 9999999999, 0)",
        rusqlite::params![instance_id.to_string(), state],
    )
    .unwrap();
}

#[test]
fn an_outstanding_durable_reservation_defers_the_idle_unload() {
    for reservation_state in ["reserved", "accepted", "cancel_requested"] {
        let (manager, backend) = ready_engine();
        let instance_id = manager.inner.lock().instance.as_ref().unwrap().instance_id;
        reserve_durable_work(&manager, instance_id, reservation_state);
        let before = manager.inner.lock().instance.clone().unwrap();

        let (instance, generation, timeout) = manager.idle().idle_watch_configuration().unwrap();
        let sleeps = Cell::new(0);
        manager.idle().idle_watch_with(
            instance,
            generation,
            timeout,
            |_| {
                sleeps.set(sleeps.get() + 1);
                assert_eq!(
                    manager.inner.lock().state,
                    EngineState::Ready,
                    "{reservation_state}: the engine must stay ready for its durable work"
                );
                // Releasing the reservation lets the expired deadline take effect on the next pass.
                manager
                    .db
                    .lock()
                    .execute(
                        "UPDATE inference_reservations SET capacity_released = 1",
                        [],
                    )
                    .unwrap();
            },
            |_| timeout,
        );

        assert_eq!(
            sleeps.get(),
            1,
            "{reservation_state}: the watchdog must rearm rather than unload durable work"
        );
        assert_eq!(
            manager.inner.lock().state,
            EngineState::Unloaded,
            "{reservation_state}: the unload proceeds once the reservation is released"
        );
        let rt = tokio::runtime::Runtime::new().unwrap();
        assert!(!rt.block_on(backend.is_running(&before)));
    }
}

fn save_idle_setting(manager: &EngineManager, policy: &str, seconds: Option<u64>) {
    let instance = manager.inner.lock().instance.clone().unwrap();
    let conn = manager.db.lock();
    conn.execute("INSERT OR IGNORE INTO devices(id, display_name, platform, public_key_spki, public_key_fingerprint, role, paired_at) VALUES ('idle-owner','Owner','ios',x'00','idle-fingerprint','owner','2026-09-06T00:00:00Z')", []).unwrap();
    conn.execute("INSERT OR REPLACE INTO model_idle_policies(model_id, profile_id, idle_policy, updated_at, updated_by_device_id) VALUES (?1,?2,?3,'2026-09-06T00:00:00Z','idle-owner')",
        rusqlite::params![instance.model_id, instance.profile_id, policy]).unwrap();
    if let Some(seconds) = seconds {
        conn.execute("INSERT INTO model_idle_timeouts(model_id, profile_id, timeout_seconds) VALUES (?1,?2,?3)", rusqlite::params![instance.model_id, instance.profile_id, seconds]).unwrap();
    }
}

#[test]
fn custom_idle_timeout_is_read_from_the_spark_and_stops_at_its_deadline() {
    let (manager, _) = ready_engine();
    save_idle_setting(&manager, "unload_after_30m", Some(42 * 60));
    let (instance, generation, timeout) = manager.idle().idle_watch_configuration().unwrap();
    assert_eq!(timeout, Duration::from_secs(42 * 60));
    let elapsed = Cell::new(Duration::ZERO);
    manager.idle().idle_watch_with(
        instance,
        generation,
        timeout,
        |delay| elapsed.set(elapsed.get() + delay),
        |_| elapsed.get(),
    );
    assert_eq!(elapsed.get(), timeout);
    assert_eq!(manager.inner.lock().state, EngineState::Unloaded);
}

#[test]
fn never_unload_cancels_an_existing_idle_timer_and_a_timed_policy_rearms_it() {
    let (manager, backend) = ready_engine();
    let manager = Arc::new(manager);
    let (instance, generation, timeout) = manager.idle().idle_watch_configuration().unwrap();
    let active = manager.inner.lock().instance.clone().unwrap();
    save_idle_setting(&manager, "keep_ready", None);
    manager.refresh_idle_policy(&active.model_id, &active.profile_id);
    assert!(manager.idle().idle_watch_configuration().is_none());
    manager.idle().idle_watch_with(
        instance,
        generation,
        timeout,
        |_| panic!("obsolete timer slept"),
        |_| timeout,
    );
    assert_eq!(manager.inner.lock().state, EngineState::Ready);
    assert!(
        tokio::runtime::Runtime::new()
            .unwrap()
            .block_on(backend.is_running(&active))
    );
    save_idle_setting(&manager, "unload_after_30m", None);
    assert_eq!(
        manager.idle().idle_watch_configuration().unwrap().2,
        Duration::from_secs(1800)
    );
}
