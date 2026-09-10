#[test]
fn download_progress_is_persisted_before_live_fanout() {
    let (database, jobs, operation_id, recipe) = seeded_sink_fixture();
    let lease = jobs.acquire_lease(database.clone(), operation_id).unwrap();
    let events = EventBus::new();
    let mut receiver = events.subscribe();
    let sink = DbProgressSink {
        database: database.clone(),
        events,
        node_id: "node-1".into(),
        operation_id,
        model_id: recipe.id().into(),
        lease: &lease,
        last_written: parking_lot::Mutex::new(None),
    };

    sink.note("weights.bin", 0, 1, 50, 100).unwrap();

    let live = receiver.try_recv().expect("live progress event");
    assert_eq!(live["sequence"], 1);
    assert_eq!(live["type"], "model.download.progress");
    let conn = database.lock();
    let persisted: (String, String) = conn
        .query_row(
            "SELECT event_type, operation_id FROM events WHERE sequence = 1",
            [],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .unwrap();
    assert_eq!(persisted.0, "model.download.progress");
    assert_eq!(persisted.1, operation_id.to_string());
    let progress: (i64, String) = conn
        .query_row(
            "SELECT completed_bytes, download_state FROM model_files
              WHERE model_id = ?1 AND relative_path = 'weights.bin'",
            [recipe.id()],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .unwrap();
    assert_eq!(progress, (50, "downloading".into()));
}
