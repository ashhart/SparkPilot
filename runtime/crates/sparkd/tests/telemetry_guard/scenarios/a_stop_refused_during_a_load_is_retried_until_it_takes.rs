#[test]
fn a_stop_refused_during_a_load_is_retried_until_it_takes() {
    // Retry guard stops refused during load transitions because the pressure ladder does not emit Emergency anew each tick.
    let source = Arc::new(ScriptedSource::new(vec![sample(4), sample(4)]));
    let engine = Arc::new(TransitioningEngine::new(2));
    let guard = Arc::new(
        MemoryGuardService::without_database_for_testing(
            MemoryPolicy::default(),
            source,
            engine.clone() as Arc<dyn EngineControl>,
            EventBus::new(),
        )
        .with_technical_diagnostics(Arc::new(AtomicBool::new(true))),
    );

    guard.tick(Duration::from_secs(0), "node-1");
    assert_eq!(
        engine.stop_count(),
        0,
        "the stop is refused while the engine is transitioning"
    );

    guard.tick(Duration::from_secs(1), "node-1");
    assert_eq!(
        engine.stop_count(),
        1,
        "the refused stop is retried on the next tick and takes effect"
    );
}
