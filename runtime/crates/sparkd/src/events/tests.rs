use super::*;
use crate::clock::ManualUtcClock;
use crate::events::event_stream::retained_visible_batch;
use axum::response::{IntoResponse, Sse};
use futures::StreamExt as _;
use serde_json::json;
use time::{OffsetDateTime, format_description::well_known::Rfc3339};

fn registered_owner_viewer(database: &Arc<parking_lot::Mutex<Connection>>) -> Viewer {
    let viewer = owner_viewer();
    crate::store::insert_device(
        &database.lock(),
        &viewer.device_id,
        "Owner",
        "macos",
        &[1],
        &viewer.device_id.to_string(),
        "owner",
    )
    .unwrap();
    viewer
}

#[tokio::test]
async fn existing_stream_closes_after_revocation_role_or_membership_change() {
    for change in ["revoke", "role", "membership"] {
        let mut conn = Connection::open_in_memory().unwrap();
        crate::migration::migrate(&mut conn).unwrap();
        let database = Arc::new(parking_lot::Mutex::new(conn));
        let id = Uuid::new_v4();
        crate::store::insert_device(
            &database.lock(),
            &id,
            "Admin",
            "macos",
            &[1],
            "admin-fp",
            "administrator",
        )
        .unwrap();
        let project = Uuid::new_v4();
        let mut viewer = Viewer::new(id, Role::Administrator, HashSet::new());
        if change == "membership" {
            crate::store::insert_project(
                &database.lock(),
                &project,
                "Project",
                &id,
                "/tmp/project",
                None,
            )
            .unwrap();
            crate::store::insert_project_member(&database.lock(), &project, &id, "write").unwrap();
            viewer.projects.insert(project);
        }
        let bus = EventBus::new();
        let receiver = bus.subscribe();
        let snapshot = retained_public_after(&database.lock(), None).unwrap();
        let response =
            Sse::new(resumed_stream(snapshot, receiver, database.clone(), viewer)).into_response();
        let mut body = response.into_body().into_data_stream();
        bus.emit(
            Some(&database.lock()),
            "node",
            None,
            "first",
            "info",
            json!({}),
        );
        assert!(
            body.next()
                .await
                .unwrap()
                .unwrap()
                .starts_with(b"event: first")
        );
        match change {
            "revoke" => crate::store::revoke_device(&database.lock(), &id).unwrap(),
            "role" => {
                crate::store::update_device(&database.lock(), &id, None, Some("observer")).unwrap()
            }
            _ => {
                database
                    .lock()
                    .execute(
                        "DELETE FROM project_members WHERE device_id = ?1",
                        [id.to_string()],
                    )
                    .unwrap();
            }
        }
        bus.emit_scoped(
            Some(&database.lock()),
            "node",
            None,
            "security.changed",
            "warning",
            json!({}),
            Visibility::min_role(Role::Administrator),
        );
        assert!(
            tokio::time::timeout(std::time::Duration::from_secs(1), body.next())
                .await
                .unwrap()
                .is_none(),
            "{change}"
        );
    }
}

fn owner_viewer() -> Viewer {
    Viewer::new(Uuid::new_v4(), Role::Owner, HashSet::new())
}

#[test]
fn envelope_matches_schema_shape() {
    let initial = OffsetDateTime::parse("2024-03-04T05:06:07Z", &Rfc3339).unwrap();
    let clock = Arc::new(ManualUtcClock::new(initial));
    let bus = EventBus::with_clock(clock.clone());
    let mut conn = Connection::open_in_memory().unwrap();
    crate::migration::migrate(&mut conn).unwrap();
    let mut rx = bus.subscribe();
    bus.emit(
        Some(&conn),
        "node-1",
        Some(Uuid::new_v4()),
        "model.download.progress",
        "info",
        json!({ "stage": "download", "progress": 0.42 }),
    );
    let frame = rx.blocking_recv().expect("live event");
    assert_eq!(frame["type"], "model.download.progress");
    assert_eq!(frame["payload"]["progress"], 0.42);
    assert_eq!(frame["occurred_at"], "2024-03-04T05:06:07Z");
    assert!(
        frame["sequence"].as_i64().unwrap() > 0,
        "durable sequence assigned"
    );
    let encoded = EventBus::sse_frame(&frame).unwrap();
    assert!(encoded.starts_with("id: "));
    assert!(encoded.contains("event: model.download.progress"));
    assert!(encoded.contains("data: "));
    assert!(EventBus::sse_frame(&json!({ "sequence": 0 })).is_none());

    clock.advance(time::Duration::seconds(1));
    bus.emit(
        Some(&conn),
        "node-1",
        None,
        "model.ready",
        "info",
        json!({}),
    );
    let second = rx.blocking_recv().expect("second live event");
    assert_eq!(second["occurred_at"], "2024-03-04T05:06:08Z");
    let persisted: Vec<String> = conn
        .prepare("SELECT occurred_at FROM events ORDER BY sequence")
        .unwrap()
        .query_map([], |row| row.get(0))
        .unwrap()
        .collect::<Result<_, _>>()
        .unwrap();
    assert_eq!(
        persisted,
        vec!["2024-03-04T05:06:07Z", "2024-03-04T05:06:08Z"]
    );
}

#[tokio::test]
async fn subscribe_before_snapshot_reconciles_replay_and_live_without_a_duplicate() {
    let mut conn = Connection::open_in_memory().unwrap();
    crate::migration::migrate(&mut conn).unwrap();
    let database = Arc::new(parking_lot::Mutex::new(conn));
    let bus = EventBus::new();

    // Exercise the event present in both live receiver and replay snapshot during handoff.
    let receiver = bus.subscribe();
    let snapshot = {
        let conn = database.lock();
        bus.emit(
            Some(&conn),
            "node-1",
            Some(Uuid::new_v4()),
            "operation.progress",
            "info",
            json!({ "stage": "racing" }),
        );
        retained_public_after(&conn, Some(0)).unwrap()
    };
    let response = Sse::new(resumed_stream(
        snapshot,
        receiver,
        database.clone(),
        registered_owner_viewer(&database),
    ))
    .into_response();
    let mut body = response.into_body().into_data_stream();

    let first = body.next().await.unwrap().unwrap();
    let first = String::from_utf8(first.to_vec()).unwrap();
    assert!(first.contains("event: operation.progress"));
    assert!(first.contains("id: 1"));

    {
        let conn = database.lock();
        bus.emit(
            Some(&conn),
            "node-1",
            Some(Uuid::new_v4()),
            "operation.completed",
            "info",
            json!({}),
        );
    }
    let second = body.next().await.unwrap().unwrap();
    let second = String::from_utf8(second.to_vec()).unwrap();
    assert!(second.contains("event: operation.completed"), "{second}");
    assert!(second.contains("id: 2"), "{second}");
}

#[tokio::test]
async fn no_cursor_keeps_an_event_that_races_the_snapshot() {
    let mut conn = Connection::open_in_memory().unwrap();
    crate::migration::migrate(&mut conn).unwrap();
    let database = Arc::new(parking_lot::Mutex::new(conn));
    let bus = EventBus::new();
    let receiver = bus.subscribe();
    let snapshot = {
        let conn = database.lock();
        bus.emit(
            Some(&conn),
            "node-1",
            None,
            "operation.created",
            "info",
            json!({}),
        );
        retained_public_after(&conn, None).unwrap()
    };
    let response = Sse::new(resumed_stream(
        snapshot,
        receiver,
        database.clone(),
        registered_owner_viewer(&database),
    ))
    .into_response();
    let mut body = response.into_body().into_data_stream();

    let frame = body.next().await.unwrap().unwrap();
    let frame = String::from_utf8(frame.to_vec()).unwrap();
    assert!(frame.contains("event: operation.created"), "{frame}");
    assert!(frame.contains("id: 1"), "{frame}");
}

#[test]
fn retained_replay_is_fetched_in_fixed_size_batches() {
    let mut conn = Connection::open_in_memory().unwrap();
    crate::migration::migrate(&mut conn).unwrap();
    let bus = EventBus::new();
    let total = REPLAY_BATCH_SIZE * 2 + 3;
    for index in 0..total {
        bus.emit(
            Some(&conn),
            "node-1",
            Some(Uuid::new_v4()),
            "operation.progress",
            "info",
            json!({ "index": index }),
        );
    }

    let mut after = 0;
    let mut sequences = Vec::new();
    while after < total as i64 {
        let batch = retained_visible_batch(&conn, after, total as i64, &owner_viewer()).unwrap();
        assert!(batch.envelopes.len() <= REPLAY_BATCH_SIZE);
        assert!(batch.scanned_through - after <= REPLAY_BATCH_SIZE as i64);
        sequences.extend(
            batch
                .envelopes
                .iter()
                .map(|event| event["sequence"].as_i64().unwrap()),
        );
        after = batch.scanned_through;
    }

    assert_eq!(sequences, (1..=total as i64).collect::<Vec<_>>());
}

#[test]
fn a_project_event_replays_only_to_members_of_that_project() {
    let mut conn = Connection::open_in_memory().unwrap();
    crate::migration::migrate(&mut conn).unwrap();
    let bus = EventBus::new();
    let project_a = Uuid::new_v4();
    let project_b = Uuid::new_v4();
    bus.emit_scoped(
        Some(&conn),
        "node-1",
        None,
        "agent.change.ready",
        "info",
        json!({ "change": "x" }),
        Visibility::project(project_a),
    );

    let member = Viewer::new(Uuid::new_v4(), Role::Developer, [project_a].into());
    let outsider = Viewer::new(Uuid::new_v4(), Role::Owner, [project_b].into());

    assert_eq!(
        retained_visible_batch(&conn, 0, 1, &member)
            .unwrap()
            .envelopes
            .len(),
        1
    );
    assert!(
        retained_visible_batch(&conn, 0, 1, &outsider)
            .unwrap()
            .envelopes
            .is_empty(),
        "a project event must not replay to a non-member, whatever its global role"
    );
}

#[test]
fn role_and_device_scoped_events_are_filtered() {
    let mut conn = Connection::open_in_memory().unwrap();
    crate::migration::migrate(&mut conn).unwrap();
    let bus = EventBus::new();
    let target = Uuid::new_v4();
    bus.emit_scoped(
        Some(&conn),
        "node-1",
        None,
        "security.signature.rejected",
        "warning",
        json!({}),
        Visibility::min_role(Role::Administrator),
    );
    bus.emit_scoped(
        Some(&conn),
        "node-1",
        None,
        "device.revoked",
        "warning",
        json!({}),
        Visibility::device(target),
    );

    let developer = Viewer::new(Uuid::new_v4(), Role::Developer, HashSet::new());
    assert!(
        retained_visible_batch(&conn, 0, 2, &developer)
            .unwrap()
            .envelopes
            .is_empty()
    );

    let administrator = Viewer::new(Uuid::new_v4(), Role::Administrator, HashSet::new());
    assert_eq!(
        retained_visible_batch(&conn, 0, 2, &administrator)
            .unwrap()
            .envelopes
            .len(),
        1,
        "an administrator sees the role-scoped event but not another device's"
    );

    let addressed = Viewer::new(target, Role::User, HashSet::new());
    assert_eq!(
        retained_visible_batch(&conn, 0, 2, &addressed)
            .unwrap()
            .envelopes
            .len(),
        1
    );
}

#[test]
fn an_unparseable_stored_rule_is_never_shown() {
    let mut conn = Connection::open_in_memory().unwrap();
    crate::migration::migrate(&mut conn).unwrap();
    conn.execute(
        "INSERT INTO events
            (event_id, event_type, severity, occurred_at, node_id, visibility_json, payload_json)
         VALUES ('e', 'node.status.changed', 'info', '2026-01-01T00:00:00Z', 'n',
                 '{\"unknown_rule\":true}', '{}')",
        [],
    )
    .unwrap();
    let owner = Viewer::new(Uuid::new_v4(), Role::Owner, HashSet::new());
    assert!(
        retained_visible_batch(&conn, 0, 1, &owner)
            .unwrap()
            .envelopes
            .is_empty()
    );
}

#[tokio::test]
async fn the_live_stream_filters_the_same_way_replay_does() {
    let mut conn = Connection::open_in_memory().unwrap();
    crate::migration::migrate(&mut conn).unwrap();
    let database = Arc::new(parking_lot::Mutex::new(conn));
    let bus = EventBus::new();
    let project = Uuid::new_v4();
    let receiver = bus.subscribe();
    let snapshot = {
        let conn = database.lock();
        retained_public_after(&conn, None).unwrap()
    };
    let outsider = registered_owner_viewer(&database);
    let response = Sse::new(resumed_stream(
        snapshot,
        receiver,
        database.clone(),
        outsider,
    ))
    .into_response();
    let mut body = response.into_body().into_data_stream();

    {
        let conn = database.lock();
        bus.emit_scoped(
            Some(&conn),
            "node-1",
            None,
            "project.file.changed",
            "info",
            json!({}),
            Visibility::project(project),
        );
        bus.emit(
            Some(&conn),
            "node-1",
            None,
            "node.status.changed",
            "info",
            json!({}),
        );
    }

    let frame = body.next().await.unwrap().unwrap();
    let frame = String::from_utf8(frame.to_vec()).unwrap();
    assert!(
        frame.contains("event: node.status.changed"),
        "the project event must be skipped, not delivered: {frame}"
    );
    assert!(!frame.contains("project.file.changed"), "{frame}");
    assert!(!frame.contains("_visibility"), "{frame}");
}

#[test]
fn oversized_event_is_not_persisted_or_sse_encodable() {
    let mut conn = Connection::open_in_memory().unwrap();
    crate::migration::migrate(&mut conn).unwrap();
    let bus = EventBus::new();
    let mut receiver = bus.subscribe();
    bus.emit(
        Some(&conn),
        "node-1",
        None,
        "operation.progress",
        "warning",
        json!({ "chunk": "x".repeat(MAX_EVENT_ENVELOPE_BYTES) }),
    );

    let live = receiver.try_recv().unwrap();
    assert_eq!(live["sequence"], 0);
    assert!(EventBus::sse_frame(&live).is_none());
    let count: i64 = conn
        .query_row("SELECT COUNT(*) FROM events", [], |row| row.get(0))
        .unwrap();
    assert_eq!(count, 0);
}
