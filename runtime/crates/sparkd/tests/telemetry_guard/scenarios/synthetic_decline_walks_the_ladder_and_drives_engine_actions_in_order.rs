#[test]
fn synthetic_decline_walks_the_ladder_and_drives_engine_actions_in_order() {
    let source = Arc::new(ScriptedSource::new(vec![]));
    let engine = Arc::new(RecordingEngine::default());
    *engine.active.lock().unwrap() = true;
    let (guard, mut rx) = guard_with(source.clone(), engine.clone(), None);

    // Hold each pressure rung beyond dwell, then cross the emergency floor at 4 GiB.
    let schedule: Vec<u64> = vec![60, 15, 15, 15, 15, 12, 12, 12, 12, 8, 8, 8, 8, 4];
    for (second, available) in schedule.iter().enumerate() {
        source.queue(sample(*available));
        guard.tick(Duration::from_secs(second as u64), "node-1");
    }

    let actions = engine.actions.lock().unwrap().clone();
    assert_eq!(
        actions,
        vec!["drain", "graceful_unload", "emergency_stop"],
        "guard must drain before unloading before stopping"
    );

    let events = collect_events(&mut rx);
    let types = event_types(&events);
    assert!(types.contains(&"node.memory.pressure.changed"));
    assert!(types.contains(&"model.memory.guard.armed"));
    assert!(types.contains(&"model.draining"));
    assert!(types.contains(&"model.memory.guard.triggered"));

    let triggered = events
        .iter()
        .find(|e| e["type"] == "model.memory.guard.triggered")
        .unwrap();
    assert_eq!(triggered["severity"], "critical");
    // Diagnostics ring buffer is attached to the emergency event.
    let diagnostics = triggered["payload"]["diagnostics"].as_array().unwrap();
    assert!(!diagnostics.is_empty());

    let changed = events
        .iter()
        .rfind(|e| e["type"] == "node.memory.pressure.changed")
        .unwrap();
    assert_eq!(changed["payload"]["to"], "emergency");
    assert_eq!(changed["payload"]["api_pressure"], "emergency");
}
