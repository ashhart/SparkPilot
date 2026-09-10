/// Sustained heat may stop admissions and unload gracefully but cannot trigger memory emergency or mark profiles unsafe.
#[test]
fn sustained_heat_drains_then_unloads_without_claiming_memory_pressure() {
    let source = Arc::new(ScriptedSource::new(vec![]));
    let engine = Arc::new(RecordingEngine::default());
    *engine.active.lock().unwrap() = true;
    let (guard, mut rx) = guard_with(source.clone(), engine.clone(), None);

    // Keep memory calm and verify a single hot sample causes no action.
    source.queue(sample(60).with_gpu_celsius(86.0));
    guard.tick(Duration::from_secs(0), "node-1");
    assert!(
        engine.actions.lock().unwrap().is_empty(),
        "a single hot sample must not act"
    );

    // Hold hot past the escalation minimum -> stop admitting new work.
    for second in 1..=40u64 {
        source.queue(sample(60).with_gpu_celsius(86.0));
        guard.tick(Duration::from_secs(second), "node-1");
    }
    assert_eq!(engine.actions.lock().unwrap().clone(), vec!["drain"]);

    // Push past critical -> graceful unload, and nothing harsher.
    for second in 41..=90u64 {
        source.queue(sample(60).with_gpu_celsius(95.0));
        guard.tick(Duration::from_secs(second), "node-1");
    }
    assert_eq!(
        engine.actions.lock().unwrap().clone(),
        vec!["drain", "graceful_unload"],
        "thermal must never emergency-stop"
    );

    let events = collect_events(&mut rx);
    let types = event_types(&events);
    assert!(
        types.contains(&"node.temperature.warning"),
        "the owner must be told why inference stopped; saw {types:?}"
    );
    assert!(
        !types.contains(&"node.memory.pressure.changed"),
        "memory was calm throughout; the guard must not claim memory pressure"
    );
}

#[test]
fn a_thermal_drain_resumes_after_cooling_but_not_after_losing_sensors() {
    let source = Arc::new(ScriptedSource::new(vec![]));
    let engine = Arc::new(RecordingEngine::default());
    *engine.active.lock().unwrap() = true;
    let (guard, _) = guard_with(source.clone(), engine.clone(), None);
    for second in 0..=40 {
        source.queue(sample(60).with_gpu_celsius(86.0));
        guard.tick(Duration::from_secs(second), "node-1");
    }
    assert_eq!(*engine.actions.lock().unwrap(), vec!["drain"]);
    for second in 41..=100 {
        source.queue(sample(60));
        guard.tick(Duration::from_secs(second), "node-1");
    }
    assert_eq!(*engine.actions.lock().unwrap(), vec!["drain"]);
    for second in 101..=240 {
        source.queue(sample(60).with_gpu_celsius(45.0));
        guard.tick(Duration::from_secs(second), "node-1");
    }
    assert_eq!(*engine.actions.lock().unwrap(), vec!["drain", "resume"]);
}
