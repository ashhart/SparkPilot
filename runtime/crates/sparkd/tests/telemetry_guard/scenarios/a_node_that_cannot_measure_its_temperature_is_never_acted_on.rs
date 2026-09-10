/// A node without temperature evidence must not acquire a new thermal action.
#[test]
fn a_node_that_cannot_measure_its_temperature_is_never_acted_on() {
    let source = Arc::new(ScriptedSource::new(vec![]));
    let engine = Arc::new(RecordingEngine::default());
    *engine.active.lock().unwrap() = true;
    let (guard, mut rx) = guard_with(source.clone(), engine.clone(), None);

    for second in 0..=120u64 {
        source.queue(sample(60)); // calm memory, no temperature at all
        guard.tick(Duration::from_secs(second), "node-1");
    }

    assert!(engine.actions.lock().unwrap().is_empty());
    assert!(!event_types(&collect_events(&mut rx)).contains(&"node.temperature.warning"));
}
