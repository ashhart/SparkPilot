use super::*;
use crate::clock::ManualUtcClock;
use std::sync::atomic::{AtomicUsize, Ordering};
use time::{OffsetDateTime, format_description::well_known::Rfc3339};

fn open(path: &std::path::Path) -> rusqlite::Connection {
    let mut conn = rusqlite::Connection::open(path).unwrap();
    crate::migration::migrate_with_recovery_point(&mut conn, path).unwrap();
    conn
}

fn seed_device(conn: &rusqlite::Connection, id: Uuid) {
    crate::store::insert_device(
        conn,
        &id,
        "idempotency test",
        "macos",
        &[1, 2, 3],
        &format!("fingerprint-{id}"),
        "owner",
    )
    .unwrap();
}

fn request(device_id: Uuid, path: &str, key: Uuid, body: &[u8]) -> IdempotencyRequest {
    IdempotencyRequest {
        device_id,
        method: "POST".into(),
        path: path.into(),
        key,
        body_hash: sha256_hex(body),
        request_id: None,
    }
}

#[test]
fn replay_survives_a_new_service_and_database_connection() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("runtime.db");
    let now = OffsetDateTime::parse("2026-08-27T12:00:00Z", &Rfc3339).unwrap();
    let clock = Arc::new(ManualUtcClock::new(now));
    let device_id = Uuid::new_v4();
    let key = Uuid::new_v4();
    let request = request(device_id, "/api/v1/inference/load", key, b"{}");
    let original = StoredResponse {
        status: StatusCode::ACCEPTED,
        body: json!({"id": Uuid::new_v4(), "state": "queued"}),
        operation_id: Some(Uuid::new_v4()),
    };

    {
        let mut conn = open(&path);
        seed_device(&conn, device_id);
        let service = IdempotencyService::new(clock.clone());
        let response = service
            .execute(&mut conn, &request, |_| Ok(original.clone()))
            .unwrap();
        assert!(response.created);
    }

    let mut reopened = open(&path);
    let restarted = IdempotencyService::new(clock);
    let replay = restarted
        .execute(&mut reopened, &request, |_| {
            panic!("a durable replay must not execute the mutation again")
        })
        .unwrap();
    assert!(!replay.created);
    assert_eq!(replay.response, original);
}

#[test]
fn mismatch_conflicts_and_device_and_path_are_separate_namespaces() {
    let mut conn = rusqlite::Connection::open_in_memory().unwrap();
    crate::migration::migrate(&mut conn).unwrap();
    let first_device = Uuid::new_v4();
    let second_device = Uuid::new_v4();
    seed_device(&conn, first_device);
    seed_device(&conn, second_device);
    let key = Uuid::new_v4();
    let clock = Arc::new(ManualUtcClock::new(
        OffsetDateTime::parse("2026-08-27T12:00:00Z", &Rfc3339).unwrap(),
    ));
    let service = IdempotencyService::new(clock);
    let executions = AtomicUsize::new(0);
    let response = || StoredResponse {
        status: StatusCode::ACCEPTED,
        body: json!({"sequence": executions.fetch_add(1, Ordering::SeqCst)}),
        operation_id: None,
    };

    let first = request(first_device, "/api/v1/inference/load", key, b"one");
    service
        .execute(&mut conn, &first, |_| Ok(response()))
        .unwrap();
    let mismatch = request(first_device, "/api/v1/inference/load", key, b"two");
    assert!(matches!(
        service.execute(&mut conn, &mismatch, |_| Ok(response())),
        Err(IdempotencyError::KeyReused)
    ));

    let other_path = request(first_device, "/api/v1/inference/unload", key, b"one");
    assert!(
        service
            .execute(&mut conn, &other_path, |_| Ok(response()))
            .unwrap()
            .created
    );
    let other_device = request(second_device, "/api/v1/inference/load", key, b"one");
    assert!(
        service
            .execute(&mut conn, &other_device, |_| Ok(response()))
            .unwrap()
            .created
    );
    assert_eq!(executions.load(Ordering::SeqCst), 3);
}

#[test]
fn records_live_for_at_least_twenty_four_hours_on_the_injected_clock() {
    let mut conn = rusqlite::Connection::open_in_memory().unwrap();
    crate::migration::migrate(&mut conn).unwrap();
    let now = OffsetDateTime::parse("2026-08-27T12:00:00Z", &Rfc3339).unwrap();
    let clock = Arc::new(ManualUtcClock::new(now));
    let device = Uuid::new_v4();
    seed_device(&conn, device);
    let request = request(device, "/api/v1/inference/load", Uuid::new_v4(), b"{}");
    IdempotencyService::new(clock)
        .execute(&mut conn, &request, |_| {
            Ok(StoredResponse {
                status: StatusCode::ACCEPTED,
                body: json!({}),
                operation_id: None,
            })
        })
        .unwrap();
    let expires_at: String = conn
        .query_row("SELECT expires_at FROM idempotency_records", [], |row| {
            row.get(0)
        })
        .unwrap();
    let expiry = OffsetDateTime::parse(&expires_at, &Rfc3339).unwrap();
    assert!(expiry - now >= Duration::hours(24));
}

#[test]
fn audit_failure_rolls_back_operation_and_replay_record() {
    let mut conn = rusqlite::Connection::open_in_memory().unwrap();
    crate::migration::migrate(&mut conn).unwrap();
    let device = Uuid::new_v4();
    seed_device(&conn, device);
    let request = request(device, "/api/v1/inference/load", Uuid::new_v4(), b"{}");
    let clock = Arc::new(ManualUtcClock::new(
        OffsetDateTime::parse("2026-08-28T09:30:00Z", &Rfc3339).unwrap(),
    ));
    let service = IdempotencyService::new(clock.clone());
    let jobs = JobService::with_clock(clock);
    let result = service.create_operation_audited(
        &mut conn,
        &request,
        &jobs,
        "model.load",
        Some("example/model-32b"),
        "{}",
        "administrator",
        "/api/v1/inference/load",
        Some("model/example/model-32b"),
        &json!({ "provider_token": "must-not-land" }),
    );
    let error = result.unwrap_err();
    let envelope = error.envelope();
    assert_eq!(envelope.0, StatusCode::SERVICE_UNAVAILABLE);
    assert_eq!(envelope.1["error"]["code"], "AUDIT_UNAVAILABLE");
    for table in ["operations", "idempotency_records", "audit_records"] {
        let count: i64 = conn
            .query_row(&format!("SELECT COUNT(*) FROM {table}"), [], |row| {
                row.get(0)
            })
            .unwrap();
        assert_eq!(count, 0, "{table} rolled back");
    }
}

#[test]
fn audited_operation_replay_does_not_append_a_second_record() {
    let mut conn = rusqlite::Connection::open_in_memory().unwrap();
    crate::migration::migrate(&mut conn).unwrap();
    let device = Uuid::new_v4();
    seed_device(&conn, device);
    let request = request(device, "/api/v1/inference/load", Uuid::new_v4(), b"{}");
    let clock = Arc::new(ManualUtcClock::new(
        OffsetDateTime::parse("2026-08-28T09:30:00Z", &Rfc3339).unwrap(),
    ));
    let service = IdempotencyService::new(clock.clone());
    let jobs = JobService::with_clock(clock);
    let details = json!({ "profile_id": "balanced", "replace_active": false });

    let create = |conn: &mut rusqlite::Connection| {
        service.create_operation_audited(
            conn,
            &request,
            &jobs,
            "model.load",
            Some("example/model-32b"),
            "{}",
            "administrator",
            "/api/v1/inference/load",
            Some("model/example/model-32b"),
            &details,
        )
    };
    let first = create(&mut conn).unwrap();
    let replay = create(&mut conn).unwrap();

    assert!(first.created);
    assert!(!replay.created);
    assert_eq!(replay.response, first.response);
    let counts: (i64, i64, i64) = conn
        .query_row(
            "SELECT
                (SELECT COUNT(*) FROM operations),
                (SELECT COUNT(*) FROM idempotency_records),
                (SELECT COUNT(*) FROM audit_records)",
            [],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
        )
        .unwrap();
    assert_eq!(counts, (1, 1, 1));
}
