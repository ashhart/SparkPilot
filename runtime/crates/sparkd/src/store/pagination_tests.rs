use super::*;

fn operations_table(conn: &Connection) {
    conn.execute_batch(
        "CREATE TABLE operations (
            id TEXT PRIMARY KEY, kind TEXT NOT NULL, state TEXT NOT NULL,
            actor_device_id TEXT NOT NULL, resource_id TEXT, progress REAL,
            stage TEXT, created_at TEXT NOT NULL, updated_at TEXT NOT NULL,
            started_at TEXT, completed_at TEXT, error_code TEXT,
            result_json TEXT, cancellable INTEGER NOT NULL, input_json TEXT);",
    )
    .unwrap();
}

fn insert_operation(conn: &Connection, id: &str, actor: Uuid, created_at: &str) {
    conn.execute(
        "INSERT INTO operations
            (id, kind, state, actor_device_id, created_at, updated_at, cancellable)
         VALUES (?1, 'model.install', 'running', ?2, ?3, ?3, 1)",
        rusqlite::params![id, actor.to_string(), created_at],
    )
    .unwrap();
}

#[test]
fn pages_operations_newest_first_without_gap_or_overlap() {
    let conn = Connection::open_in_memory().unwrap();
    operations_table(&conn);
    let actor = Uuid::new_v4();
    for i in 0..5u32 {
        insert_operation(
            &conn,
            &format!("00000000-0000-0000-0000-00000000000{i}"),
            actor,
            &format!("2026-09-01T00:0{i}:00Z"),
        );
    }
    let mut seen = Vec::new();
    let mut cursor: Option<(String, String)> = None;
    loop {
        let (rows, more) = operation_rows_page(
            &conn,
            Some(actor),
            cursor.as_ref().map(|(a, b)| (a.as_str(), b.as_str())),
            2,
        )
        .unwrap();
        for row in &rows {
            seen.push(row.created_at.clone());
        }
        match rows.last() {
            Some(last) if more => cursor = Some((last.created_at.clone(), last.id.to_string())),
            _ => break,
        }
    }
    assert_eq!(
        seen,
        vec![
            "2026-09-01T00:04:00Z",
            "2026-09-01T00:03:00Z",
            "2026-09-01T00:02:00Z",
            "2026-09-01T00:01:00Z",
            "2026-09-01T00:00:00Z",
        ]
    );
}

fn events_table(conn: &Connection) {
    conn.execute_batch(
        "CREATE TABLE events (
            sequence INTEGER PRIMARY KEY AUTOINCREMENT, event_id TEXT NOT NULL,
            event_type TEXT NOT NULL, severity TEXT NOT NULL, occurred_at TEXT NOT NULL,
            node_id TEXT NOT NULL, cluster_id TEXT, operation_id TEXT, resource_id TEXT,
            visibility_json TEXT NOT NULL DEFAULT '{}', payload_json TEXT NOT NULL DEFAULT '{}');",
    )
    .unwrap();
}

#[test]
fn prune_events_keeps_only_the_newest_rows() {
    let conn = Connection::open_in_memory().unwrap();
    events_table(&conn);
    for i in 0..5 {
        conn.execute(
            "INSERT INTO events (event_id, event_type, severity, occurred_at, node_id)
             VALUES (?1, 'operation.progress', 'info', '2026-09-01T00:00:00Z', 'node')",
            rusqlite::params![format!("event-{i}")],
        )
        .unwrap();
    }
    // A year later every retention window has passed, so only the replay floor still applies.
    let later = "2027-09-01T00:00:00Z";
    let keep_two = crate::events::EventRetention {
        replay_minimum_rows: 2,
        ..crate::events::EventRetention::default()
    };
    // Keep the newest 2; three older rows are removed.
    assert_eq!(prune_events(&conn, &keep_two, later).unwrap(), 3);
    let remaining: Vec<i64> = conn
        .prepare("SELECT sequence FROM events ORDER BY sequence")
        .unwrap()
        .query_map([], |row| row.get(0))
        .unwrap()
        .collect::<Result<_, _>>()
        .unwrap();
    assert_eq!(remaining, vec![4, 5]);
    // Idempotent: a second prune at the same size removes nothing.
    assert_eq!(prune_events(&conn, &keep_two, later).unwrap(), 0);
    // A keep larger than the row count removes nothing.
    let keep_many = crate::events::EventRetention {
        replay_minimum_rows: 100,
        ..crate::events::EventRetention::default()
    };
    assert_eq!(prune_events(&conn, &keep_many, later).unwrap(), 0);
}

#[test]
fn a_viewer_sees_only_its_own_operations() {
    let conn = Connection::open_in_memory().unwrap();
    operations_table(&conn);
    let me = Uuid::new_v4();
    let other = Uuid::new_v4();
    insert_operation(
        &conn,
        "11111111-1111-1111-1111-111111111111",
        me,
        "2026-09-01T00:00:00Z",
    );
    insert_operation(
        &conn,
        "22222222-2222-2222-2222-222222222222",
        other,
        "2026-09-01T00:01:00Z",
    );
    let (mine, _) = operation_rows_page(&conn, Some(me), None, 50).unwrap();
    assert_eq!(mine.len(), 1);
    assert_eq!(mine[0].actor_device_id, me);
    let (all, _) = operation_rows_page(&conn, None, None, 50).unwrap();
    assert_eq!(all.len(), 2);
}

/// §60.3 gives each class its own floor, so volume in one class cannot evict another.
#[test]
fn retention_classes_protect_security_and_operation_history_from_event_volume() {
    let conn = Connection::open_in_memory().unwrap();
    events_table(&conn);
    let now = time::OffsetDateTime::parse(
        "2026-09-05T00:00:00Z",
        &time::format_description::well_known::Rfc3339,
    )
    .unwrap();
    let insert = |event_type: &str, days_old: i64, count: usize| {
        let at = crate::clock::format_utc(now - time::Duration::days(days_old));
        for index in 0..count {
            conn.execute(
                "INSERT INTO events (event_id, event_type, severity, occurred_at, node_id)
                 VALUES (?1, ?2, 'info', ?3, 'node')",
                rusqlite::params![uuid::Uuid::new_v4().to_string(), event_type, at],
            )
            .unwrap();
            let _ = index;
        }
    };
    // Oldest first so both protected rows sit far below the replay row floor.
    insert("security.signature.rejected", 60, 1);
    insert("device.revoked", 60, 1);
    insert("operation.completed", 20, 1);
    insert("inference.request.completed", 60, 40);
    insert("model.download.progress", 60, 5);
    insert("inference.request.completed", 0, 20);

    let retention = crate::events::EventRetention {
        replay_minimum_rows: 10,
        ..crate::events::EventRetention::default()
    };
    let removed = prune_events(&conn, &retention, &crate::clock::format_utc(now)).unwrap();
    assert_eq!(removed, 45, "only the aged unprotected classes are removed");

    let surviving = |event_type: &str| -> i64 {
        conn.query_row(
            "SELECT COUNT(*) FROM events WHERE event_type = ?1",
            [event_type],
            |row| row.get(0),
        )
        .unwrap()
    };
    assert_eq!(surviving("security.signature.rejected"), 1, "90-day floor");
    assert_eq!(
        surviving("device.revoked"),
        1,
        "identity events are audit class"
    );
    assert_eq!(surviving("operation.completed"), 1, "30-day floor");
    // The twenty recent rows are inside the replay window; the aged forty are not.
    assert_eq!(surviving("inference.request.completed"), 20);
    assert_eq!(surviving("model.download.progress"), 0);
    // Idempotent at the same instant.
    assert_eq!(
        prune_events(&conn, &retention, &crate::clock::format_utc(now)).unwrap(),
        0
    );
}

/// The replay floor is the larger of a row count and a time window (§60.3).
#[test]
fn the_replay_window_keeps_recent_rows_beyond_the_row_floor() {
    let conn = Connection::open_in_memory().unwrap();
    events_table(&conn);
    let now = time::OffsetDateTime::parse(
        "2026-09-05T00:00:00Z",
        &time::format_description::well_known::Rfc3339,
    )
    .unwrap();
    let recent = crate::clock::format_utc(now - time::Duration::hours(6));
    for _ in 0..50 {
        conn.execute(
            "INSERT INTO events (event_id, event_type, severity, occurred_at, node_id)
             VALUES (?1, 'inference.request.completed', 'info', ?2, 'node')",
            rusqlite::params![uuid::Uuid::new_v4().to_string(), recent],
        )
        .unwrap();
    }
    let retention = crate::events::EventRetention {
        replay_minimum_rows: 5,
        ..crate::events::EventRetention::default()
    };
    assert_eq!(
        prune_events(&conn, &retention, &crate::clock::format_utc(now)).unwrap(),
        0,
        "rows inside the 24-hour replay window survive a smaller row floor"
    );
}
