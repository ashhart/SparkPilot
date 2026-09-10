/// Use a timeout to detect nested acquisition of the sink and lease's shared non-reentrant database mutex.
#[test]
fn a_stage_write_from_the_progress_sink_does_not_deadlock_on_the_database() {
    let (database, jobs, operation_id, recipe) = seeded_sink_fixture();

    // Detach the worker and observe a deadline so a real deadlock fails the test instead of hanging scoped-thread cleanup.
    let (tx, rx) = std::sync::mpsc::channel();
    let worker_db = database.clone();
    let worker_jobs = jobs.clone();
    let worker_model = recipe.id().to_owned();
    std::thread::spawn(move || {
        let lease = worker_jobs
            .acquire_lease(worker_db.clone(), operation_id)
            .unwrap();
        let sink = DbProgressSink {
            database: worker_db,
            events: EventBus::new(),
            node_id: "node-1".into(),
            operation_id,
            model_id: worker_model,
            lease: &lease,
            last_written: parking_lot::Mutex::new(None),
        };
        // Write file progress before install-wide stage progress, matching production order.
        sink.note("weights.bin", 0, 1, 50, 100).unwrap();
        sink.stage("downloading", Some(0.5));
        drop(sink);
        let _ = tx.send(());
    });

    assert!(
        rx.recv_timeout(std::time::Duration::from_secs(5)).is_ok(),
        "the progress sink deadlocked: it held the database guard across a stage write"
    );

    let conn = database.lock();
    let (stage, progress): (String, f64) = conn
        .query_row(
            "SELECT stage, progress FROM operations WHERE id = ?1",
            [operation_id.to_string()],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .unwrap();
    assert_eq!(stage, "downloading");
    assert!((progress - 0.5).abs() < 1e-9);
}
