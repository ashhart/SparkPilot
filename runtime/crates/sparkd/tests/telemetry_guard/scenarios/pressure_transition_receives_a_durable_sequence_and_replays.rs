#[tokio::test]
async fn pressure_transition_receives_a_durable_sequence_and_replays() {
    let database = Arc::new(Mutex::new(migrated_db()));
    let events = EventBus::new();
    let source = Arc::new(ScriptedSource::new(vec![]));
    let guard = MemoryGuardService::with_database(
        MemoryPolicy::default(),
        source.clone(),
        Arc::new(NoEngine),
        events.clone(),
        database.clone(),
    );

    for (second, available) in [60, 15, 15, 15, 15].into_iter().enumerate() {
        source.queue(sample(available));
        guard.tick(Duration::from_secs(second as u64), "node-1");
    }

    let receiver = events.subscribe();
    let snapshot = {
        let conn = database.lock();
        let sequence: i64 = conn
            .query_row(
                "SELECT sequence FROM events
                 WHERE event_type = 'node.memory.pressure.changed'
                 ORDER BY sequence LIMIT 1",
                [],
                |row| row.get(0),
            )
            .expect("durable pressure transition");
        assert!(sequence >= 1);
        sparkd::events::retained_public_after(&conn, Some(sequence - 1)).unwrap()
    };
    let viewer = sparkd::events::Viewer::new(
        uuid::Uuid::new_v4(),
        sparkd::capability::Role::Owner,
        Default::default(),
    );
    // Recheck durable viewer grants before every replayed event frame.
    sparkd::store::insert_device(
        &database.lock(),
        &viewer.device_id,
        "Telemetry observer",
        "macos",
        b"test-spki",
        "telemetry-replay-viewer",
        "owner",
    )
    .unwrap();
    let response = Sse::new(sparkd::events::resumed_stream(
        snapshot, receiver, database, viewer,
    ))
    .into_response();
    let mut body = response.into_body().into_data_stream();
    let frame = body.next().await.unwrap().unwrap();
    let frame = String::from_utf8(frame.to_vec()).unwrap();
    assert!(
        frame.contains("event: node.memory.pressure.changed"),
        "{frame}"
    );
    assert!(frame.contains("id: 1"), "{frame}");
}
