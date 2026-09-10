fn guard_over(
    engine: &Arc<EngineManager>,
    available: Arc<AtomicU64>,
    db: Arc<parking_lot::Mutex<rusqlite::Connection>>,
) -> Arc<sparkd::guard::MemoryGuardService> {
    let source = Arc::new(StaticSource {
        available,
        total: 240 << 30,
    });
    let events = sparkd::events::EventBus::new();
    let guard = Arc::new(sparkd::guard::MemoryGuardService::with_database(
        spark_telemetry::MemoryPolicy::default(),
        source,
        Arc::new(sparkd::guard::GuardEngine::new(engine.clone())),
        events,
        db,
    ));
    engine.set_guard(guard.clone());
    guard
}
