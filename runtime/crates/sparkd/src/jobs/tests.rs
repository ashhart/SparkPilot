use super::*;
use crate::clock::ManualUtcClock;
use time::{OffsetDateTime, format_description::well_known::Rfc3339};

fn mem() -> Connection {
    let mut conn = Connection::open_in_memory().unwrap();
    crate::migration::migrate(&mut conn).unwrap();
    conn
}

fn seed_device(conn: &Connection) -> Uuid {
    let id = Uuid::new_v4();
    crate::store::insert_device(
        conn,
        &id,
        "t",
        "macos",
        b"spki",
        &format!("fp-{id}"),
        "owner",
    )
    .unwrap();
    id
}

#[test]
fn lifecycle_transitions_and_terminal_states() {
    let database = Arc::new(Mutex::new(mem()));
    let service = JobService::new();
    let actor = seed_device(&database.lock());
    let id = service
        .create(
            &database.lock(),
            "model.install",
            actor,
            Some("example/model"),
            "{}",
        )
        .unwrap();
    let lease = service.acquire_lease(database.clone(), id).unwrap();
    lease.set_stage("download", Some(0.5)).unwrap();
    lease
        .succeed(&serde_json::json!({"installed": true}))
        .unwrap();

    let row = service.get(&database.lock(), id).unwrap().unwrap();
    assert_eq!(row.state, "succeeded");
    assert!(row.stage.is_some());
    let list = service.list(&database.lock()).unwrap();
    assert_eq!(list.len(), 1);
    // Stages cannot change the terminal state of a finished job.
    service
        .set_stage(&database.lock(), id, "download", Some(0.9))
        .unwrap();
    let row = service.get(&database.lock(), id).unwrap().unwrap();
    assert_eq!(row.state, "succeeded");
}

#[test]
fn lifecycle_timestamps_follow_the_injected_clock() {
    let database = Arc::new(Mutex::new(mem()));
    let initial = OffsetDateTime::parse("2024-02-03T04:05:06Z", &Rfc3339).unwrap();
    let clock = Arc::new(ManualUtcClock::new(initial));
    let service = JobService::with_clock(clock.clone());
    let actor = seed_device(&database.lock());

    let id = service
        .create(
            &database.lock(),
            "model.install",
            actor,
            Some("example/model"),
            "{}",
        )
        .unwrap();
    clock.advance(time::Duration::seconds(2));
    let lease = service.acquire_lease(database.clone(), id).unwrap();
    clock.advance(time::Duration::milliseconds(500));
    lease.set_stage("download", Some(0.5)).unwrap();
    clock.advance(time::Duration::seconds(3));
    lease
        .succeed(&serde_json::json!({"installed": true}))
        .unwrap();

    let timestamps: (String, String, Option<String>, Option<String>) = database
        .lock()
        .query_row(
            "SELECT created_at, updated_at, started_at, completed_at FROM operations WHERE id = ?1",
            [id.to_string()],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?)),
        )
        .unwrap();
    assert_eq!(timestamps.0, "2024-02-03T04:05:06Z");
    assert_eq!(timestamps.1, "2024-02-03T04:05:11.5Z");
    assert_eq!(timestamps.2.as_deref(), Some("2024-02-03T04:05:08Z"));
    assert_eq!(timestamps.3.as_deref(), Some("2024-02-03T04:05:11.5Z"));
}

#[test]
fn cancellation_is_cooperative_and_single_shot() {
    let conn = mem();
    let service = JobService::new();
    let actor = seed_device(&conn);
    let id = service
        .create(&conn, "model.download", actor, Some("m"), "{}")
        .unwrap();
    assert!(service.cancel_requested(&conn, id).unwrap());
    // Cancellation may repeat while nonterminal; terminal jobs must refuse cancellation.
    service.fail(&conn, id, "model.download_failed").unwrap();
    let row = service.get(&conn, id).unwrap().unwrap();
    assert_eq!(row.state, "failed");
    // A fresh attempt to cancel after terminal does not resurrect it.
    let actor2 = seed_device(&conn);
    let second = service
        .create(&conn, "model.download", actor2, Some("m"), "{}")
        .unwrap();
    assert!(service.cancel_requested(&conn, second).unwrap());
    assert!(service.worker_cancelled(second));
    service
        .cancelled(&conn, second, "OPERATION_CANCELLED")
        .unwrap();
    assert!(!service.worker_cancelled(second));
    let row = service.get(&conn, second).unwrap().unwrap();
    assert_eq!(row.state, "cancelled");
    let error_code: Option<String> = conn
        .query_row(
            "SELECT error_code FROM operations WHERE id = ?1",
            [second.to_string()],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(error_code.as_deref(), Some("OPERATION_CANCELLED"));
}

#[test]
fn terminal_state_and_audit_record_are_atomic_and_single_shot() {
    let conn = mem();
    let now = OffsetDateTime::parse("2026-08-28T09:30:00Z", &Rfc3339).unwrap();
    let clock = Arc::new(ManualUtcClock::new(now));
    let service = JobService::with_clock(clock.clone());
    let actor = seed_device(&conn);
    let id = service
        .create(&conn, "model.remove", actor, Some("example/model"), "{}")
        .unwrap();
    crate::audit::append(
        &conn,
        clock.as_ref(),
        &crate::audit::AuditDraft {
            actor_device_id: Some(actor),
            actor_role: Some("owner"),
            source_route: "/api/v1/models/example%2Fmodel/remove",
            action: "model.remove",
            resource: Some("model/example/model"),
            result: "accepted",
            operation_id: Some(id),
            request_id: Some(Uuid::new_v4()),
            details: &serde_json::json!({}),
        },
    )
    .unwrap();
    conn.execute_batch(
        "CREATE TRIGGER reject_terminal_audit
         BEFORE INSERT ON audit_records
         BEGIN SELECT RAISE(ABORT, 'audit unavailable'); END;",
    )
    .unwrap();

    let error = service
        .succeed(&conn, id, &serde_json::json!({ "removed": true }))
        .unwrap_err();
    assert!(matches!(error, store::StoreError::Audit(_)));
    assert_eq!(
        service.get(&conn, id).unwrap().unwrap().state,
        "queued",
        "operation state must roll back when its terminal audit cannot persist"
    );
    conn.execute_batch("DROP TRIGGER reject_terminal_audit;")
        .unwrap();

    service
        .succeed(&conn, id, &serde_json::json!({ "removed": true }))
        .unwrap();
    assert!(
        service
            .succeed(&conn, id, &serde_json::json!({ "removed": true }))
            .is_err(),
        "a terminal operation cannot append a second terminal record"
    );
    let results: Vec<String> = conn
        .prepare("SELECT result FROM audit_records WHERE operation_id = ?1 ORDER BY sequence")
        .unwrap()
        .query_map([id.to_string()], |row| row.get(0))
        .unwrap()
        .collect::<Result<_, _>>()
        .unwrap();
    assert_eq!(results, vec!["accepted", "succeeded"]);
}

#[test]
fn every_operation_transition_publishes_its_catalogued_event() {
    let database = Arc::new(Mutex::new(mem()));
    let events = crate::events::EventBus::new();
    let mut receiver = events.subscribe();
    let service = JobService::new().with_events(events, "node-under-test");
    let actor = seed_device(&database.lock());

    let id = service
        .create(
            &database.lock(),
            "model.install",
            actor,
            Some("example/model"),
            "{}",
        )
        .unwrap();
    let lease = service.acquire_lease(database.clone(), id).unwrap();
    lease.set_stage("download", Some(0.5)).unwrap();
    lease
        .succeed(&serde_json::json!({"installed": true}))
        .unwrap();

    let mut seen = Vec::new();
    while let Ok(frame) = receiver.try_recv() {
        seen.push(frame);
    }
    let types: Vec<String> = seen
        .iter()
        .map(|frame| frame["type"].as_str().unwrap_or_default().to_owned())
        .collect();
    assert_eq!(
        types,
        vec![
            "operation.created".to_owned(),
            "operation.progress".to_owned(),
            "operation.completed".to_owned(),
        ],
        "PLAN §27.4 and §60.2 make the operation family the live backbone"
    );

    assert_eq!(seen[0]["operation_id"], id.to_string());
    assert_eq!(seen[0]["payload"]["kind"], "model.install");
    assert_eq!(seen[0]["payload"]["resource_id"], "example/model");
    assert_eq!(seen[1]["payload"]["stage"], "download");
    assert!((seen[1]["payload"]["progress"].as_f64().unwrap() - 0.5).abs() < f64::EPSILON);
    assert_eq!(seen[2]["payload"]["state"], "succeeded");

    // Every frame is durable so a reconnecting client replays it by Last-Event-ID.
    for frame in &seen {
        assert!(
            frame["sequence"].as_i64().unwrap_or_default() > 0,
            "operation events must be persisted, not live-only: {frame}"
        );
    }
    // §60.1: the envelope carries identity, never operation input or results.
    for frame in &seen {
        let encoded = frame.to_string();
        assert!(
            !encoded.contains("installed"),
            "result bodies stay out: {encoded}"
        );
    }
}

#[test]
fn a_failed_operation_publishes_its_error_code_and_a_cancellation_publishes_cancelled() {
    let database = Arc::new(Mutex::new(mem()));
    let events = crate::events::EventBus::new();
    let mut receiver = events.subscribe();
    let service = JobService::new().with_events(events, "node-under-test");
    let actor = seed_device(&database.lock());

    let failed = service
        .create(&database.lock(), "model.load", actor, None, "{}")
        .unwrap();
    service
        .fail(&database.lock(), failed, "MODEL_LOAD_FAILED")
        .unwrap();

    let cancelled = service
        .create(&database.lock(), "model.install", actor, None, "{}")
        .unwrap();
    service
        .cancelled(&database.lock(), cancelled, "OPERATION_CANCELLED")
        .unwrap();

    let mut seen = Vec::new();
    while let Ok(frame) = receiver.try_recv() {
        seen.push(frame);
    }
    let types: Vec<String> = seen
        .iter()
        .map(|frame| frame["type"].as_str().unwrap_or_default().to_owned())
        .collect();
    assert_eq!(
        types,
        vec![
            "operation.created".to_owned(),
            "operation.failed".to_owned(),
            "operation.created".to_owned(),
            "operation.cancelled".to_owned(),
        ]
    );
    assert_eq!(seen[1]["payload"]["error_code"], "MODEL_LOAD_FAILED");
    assert_eq!(seen[1]["severity"], "warning");
    assert_eq!(seen[3]["payload"]["state"], "cancelled");
}

/// BH-38: a worker whose lease was taken from it must not be able to write a terminal state.
#[test]
fn bh_38_a_stalled_worker_cannot_complete_an_operation_whose_lease_was_stolen() {
    let database = Arc::new(Mutex::new(mem()));
    let events = crate::events::EventBus::new();
    let mut receiver = events.subscribe();
    let service = JobService::new().with_events(events, "node-under-test");
    let actor = seed_device(&database.lock());
    let id = service
        .create(&database.lock(), "model.install", actor, None, "{}")
        .unwrap();

    let stalled = service.acquire_lease(database.clone(), id).unwrap();
    assert_eq!(stalled.fence(), 1);
    // The heartbeat starved and the lease expired; another worker took it.
    database
        .lock()
        .execute(
            "UPDATE operations SET lease_expires_at = '1970-01-01T00:00:00Z' WHERE id = ?1",
            [id.to_string()],
        )
        .unwrap();
    assert!(
        matches!(
            service.acquire_lease(database.clone(), id),
            Err(LeaseError::Held)
        ),
        "expiry alone must never authorise repeating an external side effect"
    );
    // Inject an ownership replacement to exercise the fence independently of safe admission.
    let replacement_owner = format!("{}:replacement", service.daemon_id());
    database
        .lock()
        .execute(
            "UPDATE operations SET lease_owner=?2, lease_fence=2 WHERE id=?1",
            rusqlite::params![id.to_string(), replacement_owner],
        )
        .unwrap();
    let thief = OperationLease::new(service.clone(), database.clone(), id, replacement_owner, 2);
    assert_eq!(thief.fence(), 2, "every acquisition raises the fence");

    let refused = stalled.succeed(&serde_json::json!({"installed": true}));
    assert!(
        matches!(refused, Err(LeaseError::Lost)),
        "the stalled worker must not settle the operation"
    );
    let row = service.get(&database.lock(), id).unwrap().unwrap();
    assert_eq!(row.state, "running", "the thief still owns the operation");
    assert!(row.completed_at.is_none(), "nothing terminal was written");

    let audited: i64 = database
        .lock()
        .query_row(
            "SELECT COUNT(*) FROM audit_records WHERE action = 'operation.lease.lost'
               AND operation_id = ?1",
            [id.to_string()],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(audited, 1, "a lost lease is audited, not discarded");
    let mut types = Vec::new();
    while let Ok(frame) = receiver.try_recv() {
        types.push(frame["type"].as_str().unwrap_or_default().to_owned());
    }
    assert!(
        types.contains(&"operation.lease.lost".to_owned()),
        "a lost lease is published: {types:?}"
    );

    thief
        .succeed(&serde_json::json!({"installed": true}))
        .unwrap();
    assert_eq!(
        service.get(&database.lock(), id).unwrap().unwrap().state,
        "succeeded"
    );
}

/// BH-38: recovery and the reaper raise the fence, so the worker they interrupted is fenced out at once.
#[test]
fn bh_38_the_reaper_raises_the_fence_it_takes() {
    let database = Arc::new(Mutex::new(mem()));
    let service = JobService::new();
    let actor = seed_device(&database.lock());
    let id = service
        .create(&database.lock(), "model.load", actor, None, "{}")
        .unwrap();
    let stalled = service.acquire_lease(database.clone(), id).unwrap();
    database
        .lock()
        .execute(
            "UPDATE operations SET lease_expires_at = '1970-01-01T00:00:00Z' WHERE id = ?1",
            [id.to_string()],
        )
        .unwrap();
    assert_eq!(
        service.reap_expired_leases(&mut database.lock()).unwrap(),
        1
    );

    let fence: i64 = database
        .lock()
        .query_row(
            "SELECT lease_fence FROM operations WHERE id = ?1",
            [id.to_string()],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(fence, stalled.fence() + 1);
    assert!(matches!(
        stalled.succeed(&serde_json::json!({})),
        Err(LeaseError::Lost)
    ));
    assert_eq!(
        service.get(&database.lock(), id).unwrap().unwrap().state,
        "failed"
    );
}

#[test]
fn recovery_never_resets_a_worker_owned_by_this_daemon() {
    let database = Arc::new(Mutex::new(mem()));
    let service = JobService::new();
    let actor = seed_device(&database.lock());
    let id = service
        .create(
            &database.lock(),
            "catalogue.refresh",
            actor,
            None,
            r#"{"candidate_json":"{}"}"#,
        )
        .unwrap();
    let lease = service.acquire_lease(database.clone(), id).unwrap();
    let (report, actions) = service.recover_abandoned(&mut database.lock()).unwrap();
    assert!(actions.is_empty());
    assert_eq!(report, RecoveryReport::default());
    lease.set_stage("continuing", None).unwrap();
    lease.fail("TEST_FINISHED").unwrap();
}

#[test]
fn an_expired_heartbeat_never_authorises_a_second_worker_to_repeat_the_side_effect() {
    let database = Arc::new(Mutex::new(mem()));
    let clock = Arc::new(ManualUtcClock::new(OffsetDateTime::now_utc()));
    let service = JobService::with_clock(clock.clone());
    let actor = seed_device(&database.lock());
    let id = service
        .create(&database.lock(), "model.load", actor, None, "{}")
        .unwrap();
    let lease = service.acquire_lease(database.clone(), id).unwrap();
    clock.advance(time::Duration::hours(1));
    assert!(matches!(
        service.acquire_lease(database.clone(), id),
        Err(LeaseError::Held)
    ));
    // Recovery marks uncertainty as terminal before the owner explicitly starts another operation.
    service.reap_expired_leases(&mut database.lock()).unwrap();
    assert!(lease.is_cancelled());
}
