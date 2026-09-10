#[test]
fn emergency_marks_the_active_profile_unsafe_and_blocks_readmission() {
    let conn = migrated_db();
    seed_profile_row(&conn);
    let environment = guard::measurement_environment("vllm@sha256:aaa", "abc123", "2026-09-06.1");
    let database = Arc::new(Mutex::new(conn));
    let source = Arc::new(ScriptedSource::new(vec![sample(60), sample(60), sample(4)]));
    let engine = Arc::new(RecordingEngine::default());
    let (guard, _rx) = guard_with(source, engine, Some(database.clone()));

    guard.set_active_profile(Some(ActiveProfile {
        model_id: "llama-8b".to_owned(),
        profile_id: "balanced-16k".to_owned(),
    }));
    guard.tick(Duration::from_secs(0), "node-1");
    guard.tick(Duration::from_secs(1), "node-1");
    guard.tick(Duration::from_secs(2), "node-1");

    assert_eq!(
        guard.reading().state,
        spark_telemetry::PressureState::Emergency
    );

    let conn = database.lock();
    assert!(guard::profile_is_unsafe(&conn, "llama-8b", "balanced-16k").unwrap());

    // Admission must refuse the now-unsafe profile even with ample headroom.
    let decision = spark_telemetry::check_admission(&spark_telemetry::AdmissionRequest {
        expected_peak_bytes: 40 * GIB,
        measured_peak_bytes: guard::measured_peak(&conn, "llama-8b", "balanced-16k", &environment)
            .unwrap(),
        signals: sample(100),
        pressure: spark_telemetry::PressureState::Normal,
        system_reserve_bytes: 21 * GIB,
        profile_unsafe: guard::profile_is_unsafe(&conn, "llama-8b", "balanced-16k").unwrap(),
    });
    assert_eq!(
        decision,
        spark_telemetry::AdmissionDecision::DenyProfileUnsafe
    );
}
