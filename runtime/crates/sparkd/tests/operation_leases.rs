//! Operation lease admission and recovery regressions for protocol section 27.3.

use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};

use parking_lot::Mutex;
use sparkd::clock::ManualUtcClock;
use sparkd::jobs::{JobService, LeaseConfig, LeaseError};
use time::{OffsetDateTime, format_description::well_known::Rfc3339};

fn seeded() -> (Arc<Mutex<rusqlite::Connection>>, JobService, uuid::Uuid) {
    let mut conn = rusqlite::Connection::open_in_memory().unwrap();
    sparkd::migration::migrate(&mut conn).unwrap();
    let actor = uuid::Uuid::new_v4();
    sparkd::store::insert_device(
        &conn,
        &actor,
        "lease test",
        "macos",
        &[1, 2, 3],
        &format!("lease-{actor}"),
        "owner",
    )
    .unwrap();
    let jobs = JobService::new();
    let operation = jobs
        .create(&conn, "test.worker", actor, None, "{}")
        .unwrap();
    (Arc::new(Mutex::new(conn)), jobs, operation)
}

fn seeded_with_clock() -> (
    Arc<Mutex<rusqlite::Connection>>,
    JobService,
    uuid::Uuid,
    Arc<ManualUtcClock>,
) {
    let now = OffsetDateTime::parse("2026-08-27T12:00:00Z", &Rfc3339).unwrap();
    let clock = Arc::new(ManualUtcClock::new(now));
    let mut conn = rusqlite::Connection::open_in_memory().unwrap();
    sparkd::migration::migrate(&mut conn).unwrap();
    let actor = uuid::Uuid::new_v4();
    sparkd::store::insert_device(
        &conn,
        &actor,
        "lease clock test",
        "macos",
        &[4, 5, 6],
        &format!("lease-clock-{actor}"),
        "owner",
    )
    .unwrap();
    let jobs = JobService::with_clock_and_lease(
        clock.clone(),
        LeaseConfig {
            lease_seconds: 30,
            heartbeat_seconds: 3_600,
            worker_count: 4,
        },
    );
    let operation = jobs
        .create(&conn, "test.worker", actor, None, "{}")
        .unwrap();
    (Arc::new(Mutex::new(conn)), jobs, operation, clock)
}

#[test]
fn concurrent_workers_cross_the_side_effect_boundary_once() {
    let (database, jobs, operation) = seeded();
    let starts = Arc::new(AtomicUsize::new(0));
    let barrier = Arc::new(std::sync::Barrier::new(3));
    let handles: Vec<_> = (0..2)
        .map(|_| {
            let database = database.clone();
            let jobs = jobs.clone();
            let starts = starts.clone();
            let barrier = barrier.clone();
            std::thread::spawn(move || {
                barrier.wait();
                if jobs.acquire_lease(database, operation).is_ok() {
                    starts.fetch_add(1, Ordering::SeqCst);
                }
            })
        })
        .collect();
    barrier.wait();
    for handle in handles {
        handle.join().unwrap();
    }

    assert_eq!(starts.load(Ordering::SeqCst), 1);
}

#[test]
fn starting_work_persists_an_owner_and_expiry() {
    let (database, jobs, operation) = seeded();
    let _lease = jobs.acquire_lease(database.clone(), operation).unwrap();
    let (owner, expiry): (Option<String>, Option<String>) = database
        .lock()
        .query_row(
            "SELECT lease_owner, lease_expires_at FROM operations WHERE id = ?1",
            [operation.to_string()],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .unwrap();
    assert!(owner.is_some());
    assert!(expiry.is_some());
}

#[test]
fn renewal_extends_from_the_injected_clock_and_live_lease_cannot_be_stolen() {
    let (database, jobs, operation, clock) = seeded_with_clock();
    let lease = jobs.acquire_lease(database.clone(), operation).unwrap();
    assert!(lease.owner().starts_with(jobs.daemon_id()));
    let initial_expiry: String = database
        .lock()
        .query_row(
            "SELECT lease_expires_at FROM operations WHERE id = ?1",
            [operation.to_string()],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(initial_expiry, "2026-08-27T12:00:30Z");

    clock.advance(time::Duration::seconds(20));
    lease.renew_now().unwrap();
    let renewed_expiry: String = database
        .lock()
        .query_row(
            "SELECT lease_expires_at FROM operations WHERE id = ?1",
            [operation.to_string()],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(renewed_expiry, "2026-08-27T12:00:50Z");
    assert!(matches!(
        jobs.acquire_lease(database.clone(), operation),
        Err(LeaseError::Held)
    ));
}

#[test]
fn expired_owner_cannot_be_replayed_and_recovery_rejects_its_late_result() {
    let (database, jobs, operation, clock) = seeded_with_clock();
    let stale = jobs.acquire_lease(database.clone(), operation).unwrap();
    clock.advance(time::Duration::seconds(31));
    assert!(matches!(
        jobs.acquire_lease(database.clone(), operation),
        Err(LeaseError::Held)
    ));
    assert_eq!(jobs.reap_expired_leases(&mut database.lock()).unwrap(), 1);
    assert!(matches!(
        stale.succeed(&serde_json::json!({"wrong": true})),
        Err(LeaseError::Lost)
    ));
    let row = jobs.get(&database.lock(), operation).unwrap().unwrap();
    assert_eq!(row.state, "failed");
    assert_eq!(row.error_code.as_deref(), Some("OPERATION_LEASE_EXPIRED"));
    assert!(row.result.is_none());
}

#[test]
fn cancellation_keeps_the_lease_until_worker_acknowledges_and_finishes_cancelled() {
    let (database, jobs, operation, _clock) = seeded_with_clock();
    let lease = jobs.acquire_lease(database.clone(), operation).unwrap();
    jobs.cancel_requested(&database.lock(), operation).unwrap();
    lease
        .succeed(&serde_json::json!({"too_late": true}))
        .unwrap();

    let (state, error, owner): (String, Option<String>, Option<String>) = database
        .lock()
        .query_row(
            "SELECT state, error_code, lease_owner FROM operations WHERE id = ?1",
            [operation.to_string()],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
        )
        .unwrap();
    assert_eq!(state, "cancelled");
    assert_eq!(error.as_deref(), Some("OPERATION_CANCELLED"));
    assert!(owner.is_none());
}

#[test]
fn terminal_transition_requires_the_winning_capability() {
    let (database, jobs, operation, _clock) = seeded_with_clock();
    let lease = jobs.acquire_lease(database.clone(), operation).unwrap();

    assert!(
        jobs.succeed(
            &database.lock(),
            operation,
            &serde_json::json!({"bypass": true})
        )
        .is_err()
    );
    assert_eq!(
        database
            .lock()
            .query_row(
                "SELECT state FROM operations WHERE id = ?1",
                [operation.to_string()],
                |row| row.get::<_, String>(0),
            )
            .unwrap(),
        "running"
    );
    lease.succeed(&serde_json::json!({"owned": true})).unwrap();
}

#[test]
fn background_heartbeat_renews_a_long_running_worker() {
    let (database, _jobs, operation, clock) = seeded_with_clock();
    let jobs = JobService::with_clock_and_lease(
        clock.clone(),
        LeaseConfig {
            lease_seconds: 3,
            heartbeat_seconds: 1,
            worker_count: 4,
        },
    );
    let lease = jobs.acquire_lease(database.clone(), operation).unwrap();
    clock.advance(time::Duration::seconds(2));
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(3);
    loop {
        let expiry: String = database
            .lock()
            .query_row(
                "SELECT lease_expires_at FROM operations WHERE id = ?1",
                [operation.to_string()],
                |row| row.get(0),
            )
            .unwrap();
        if expiry == "2026-08-27T12:00:05Z" {
            break;
        }
        assert!(
            std::time::Instant::now() < deadline,
            "heartbeat did not renew"
        );
        std::thread::sleep(std::time::Duration::from_millis(25));
    }
    clock.advance(time::Duration::seconds(2));
    assert!(matches!(
        jobs.acquire_lease(database.clone(), operation),
        Err(LeaseError::Held)
    ));
    lease.succeed(&serde_json::json!({"done": true})).unwrap();
}

#[test]
fn file_database_restart_waits_for_expiry_then_recovers_the_abandoned_worker() {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("runtime.db");
    let now = OffsetDateTime::parse("2026-08-27T12:00:00Z", &Rfc3339).unwrap();
    let clock = Arc::new(ManualUtcClock::new(now));
    let operation;
    {
        let mut conn = rusqlite::Connection::open(&path).unwrap();
        sparkd::migration::migrate_with_recovery_point(&mut conn, &path).unwrap();
        let actor = uuid::Uuid::new_v4();
        sparkd::store::insert_device(
            &conn,
            &actor,
            "restart owner",
            "macos",
            &[7, 8, 9],
            "restart-owner",
            "owner",
        )
        .unwrap();
        let jobs = JobService::with_clock_and_lease(
            clock.clone(),
            LeaseConfig {
                lease_seconds: 30,
                heartbeat_seconds: 3_600,
                worker_count: 4,
            },
        );
        operation = jobs
            .create(&conn, "model.load", actor, Some("example/model"), "{}")
            .unwrap();
        let database = Arc::new(Mutex::new(conn));
        let lease = jobs.acquire_lease(database.clone(), operation).unwrap();
        drop(lease);
        drop(database);
    }

    let recovery = JobService::with_clock_and_lease(
        clock.clone(),
        LeaseConfig {
            lease_seconds: 30,
            heartbeat_seconds: 3_600,
            worker_count: 4,
        },
    );
    let mut reopened = rusqlite::Connection::open(&path).unwrap();
    assert_eq!(
        recovery.recover_abandoned(&mut reopened).unwrap().0,
        sparkd::jobs::RecoveryReport::default()
    );
    let live_state: String = reopened
        .query_row(
            "SELECT state FROM operations WHERE id = ?1",
            [operation.to_string()],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(live_state, "running");

    clock.advance(time::Duration::seconds(31));
    let report = recovery.recover_abandoned(&mut reopened).unwrap().0;
    assert_eq!(report.failed, 1);
    let (state, error): (String, Option<String>) = reopened
        .query_row(
            "SELECT state, error_code FROM operations WHERE id = ?1",
            [operation.to_string()],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .unwrap();
    assert_eq!(state, "failed");
    assert_eq!(
        error.as_deref(),
        Some("OPERATION_ENGINE_STATE_RECONCILIATION_REQUIRED")
    );
}

#[test]
fn work_beyond_the_configured_worker_count_is_refused_not_queued() {
    // Enforce configured worker_count rather than spawning an unbounded OS thread per leased operation.
    let mut conn = rusqlite::Connection::open_in_memory().unwrap();
    sparkd::migration::migrate(&mut conn).unwrap();
    let actor = uuid::Uuid::new_v4();
    sparkd::store::insert_device(
        &conn,
        &actor,
        "bounded executor test",
        "macos",
        &[7, 8, 9],
        &format!("bounded-{actor}"),
        "owner",
    )
    .unwrap();
    let jobs = JobService::with_clock_and_lease(
        sparkd::clock::system_clock(),
        LeaseConfig {
            lease_seconds: 30,
            heartbeat_seconds: 3_600,
            worker_count: 2,
        },
    );
    let operations: Vec<uuid::Uuid> = (0..4)
        .map(|_| {
            jobs.create(&conn, "test.bounded", actor, None, "{}")
                .unwrap()
        })
        .collect();
    let database = Arc::new(Mutex::new(conn));

    // Two workers occupy the pool and stay there until released.
    let release = Arc::new(std::sync::Barrier::new(3));
    let started = Arc::new(AtomicUsize::new(0));
    for operation in &operations[..2] {
        let release = release.clone();
        let started = started.clone();
        jobs.spawn_leased(database.clone(), *operation, move |lease| {
            started.fetch_add(1, Ordering::SeqCst);
            release.wait();
            let _ = lease.succeed(&serde_json::json!({}));
        })
        .expect("the first two fit the pool");
    }
    while started.load(Ordering::SeqCst) < 2 {
        std::thread::sleep(std::time::Duration::from_millis(5));
    }

    // Report the extra worker request as immediate capacity saturation rather than an internal fault.
    let refused = jobs
        .spawn_leased(database.clone(), operations[2], |_lease| {})
        .expect_err("the pool is full");
    assert!(
        matches!(refused, LeaseError::Overloaded(2)),
        "expected saturation, got {refused:?}"
    );

    // A refused operation must not have taken a lease on the way out.
    let owner: Option<String> = database
        .lock()
        .query_row(
            "SELECT lease_owner FROM operations WHERE id = ?1",
            [operations[2].to_string()],
            |row| row.get(0),
        )
        .unwrap();
    assert!(
        owner.is_none(),
        "a refused operation must not be left holding a lease"
    );

    let metrics = jobs.worker_metrics();
    assert_eq!(metrics.capacity, 2);
    assert_eq!(metrics.in_flight, 2);
    assert_eq!(metrics.rejected, 1);
    assert_eq!(metrics.high_water_mark, 2);

    // Once the running work finishes, capacity comes back.
    release.wait();
    let mut admitted = false;
    for _ in 0..200 {
        match jobs.spawn_leased(database.clone(), operations[3], |lease| {
            let _ = lease.succeed(&serde_json::json!({}));
        }) {
            Ok(()) => {
                admitted = true;
                break;
            }
            Err(LeaseError::Overloaded(_)) => {
                std::thread::sleep(std::time::Duration::from_millis(5))
            }
            Err(other) => panic!("unexpected error: {other:?}"),
        }
    }
    assert!(admitted, "the pool must recover as workers finish");
}

#[test]
fn an_abandoned_worker_is_reaped_after_expiry_without_a_restart() {
    let (database, jobs, id, clock) = seeded_with_clock();
    let lease = jobs.acquire_lease(database.clone(), id).unwrap();
    assert_eq!(jobs.reap_expired_leases(&mut database.lock()).unwrap(), 0);
    drop(lease); // A panic unwinds the lease without declaring success.
    clock.advance(time::Duration::seconds(31));
    assert_eq!(jobs.reap_expired_leases(&mut database.lock()).unwrap(), 1);
    let row = jobs.get(&database.lock(), id).unwrap().unwrap();
    assert_eq!(row.state, "failed");
    assert_eq!(row.error_code.as_deref(), Some("OPERATION_LEASE_EXPIRED"));
    assert_eq!(jobs.reap_expired_leases(&mut database.lock()).unwrap(), 0);
    assert!(
        sparkd::audit::verify_chain(&database.lock())
            .unwrap()
            .is_none()
    );
}
