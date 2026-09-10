use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};

use parking_lot::Mutex;
use spark_privd::{BackendError, OpBackend, PrivilegedOperation, PrivilegedResponse};
use time::OffsetDateTime;
use time::format_description::well_known::Rfc3339;

use crate::clock::{ManualUtcClock, UtcClock};
use crate::jobs::{JobService, LeaseConfig};
use crate::privd::PrivilegedClient;

/// A helper that stays busy for several polls, each one moving the clock past a whole lease lifetime.
struct SlowRuntimeUpdate {
    clock: Arc<ManualUtcClock>,
    polls: AtomicUsize,
}

impl OpBackend for SlowRuntimeUpdate {
    fn execute(&self, op: &PrivilegedOperation) -> Result<PrivilegedResponse, BackendError> {
        let PrivilegedOperation::RuntimeUpdateStatus {
            request_id,
            release_id,
        } = op
        else {
            return Err(BackendError::Failure("unexpected operation".into()));
        };
        let poll = self.polls.fetch_add(1, Ordering::SeqCst);
        self.clock.advance(time::Duration::seconds(20));
        let code = if poll < 3 {
            "update.applying"
        } else {
            "update.committed"
        };
        Ok(PrivilegedResponse {
            request_id: *request_id,
            accepted: true,
            code: code.into(),
            message: String::new(),
            details: serde_json::json!({ "release_id": release_id }),
        })
    }
}

/// Housekeeping reaps stale leases every 30 s; a runtime update polls for minutes, so the poll must renew.
#[test]
fn a_runtime_update_poll_keeps_its_operation_lease_alive() {
    let dir = tempfile::tempdir().unwrap();
    let now = OffsetDateTime::parse("2026-09-05T00:00:00Z", &Rfc3339).unwrap();
    let clock = Arc::new(ManualUtcClock::new(now));
    let jobs = JobService::with_clock_and_lease(
        clock.clone() as Arc<dyn UtcClock>,
        LeaseConfig {
            lease_seconds: 30,
            heartbeat_seconds: 10,
            worker_count: 1,
        },
    );
    let mut conn = rusqlite::Connection::open(dir.path().join("runtime.db")).unwrap();
    crate::migration::migrate_with_recovery_point(&mut conn, &dir.path().join("runtime.db"))
        .unwrap();
    let actor = uuid::Uuid::new_v4();
    crate::store::insert_device(
        &conn,
        &actor,
        "lease test",
        "macos",
        &[1, 2, 3],
        "fingerprint-lease",
        "owner",
    )
    .unwrap();
    let operation = jobs
        .create(
            &conn,
            "system.software_updates",
            actor,
            None,
            r#"{"runtime_release_id":"release-1"}"#,
        )
        .unwrap();
    let database = Arc::new(Mutex::new(conn));
    let lease = jobs.acquire_lease(database.clone(), operation).unwrap();

    let socket = dir.path().join("spark-privd.sock");
    let listener = spark_privd::server::bind_socket(&socket).unwrap();
    let backend = Arc::new(SlowRuntimeUpdate {
        clock: clock.clone(),
        polls: AtomicUsize::new(0),
    });
    let served = backend.clone();
    let allowed_uid = unsafe { libc::geteuid() };
    std::thread::spawn(move || {
        let _ = spark_privd::server::serve(listener, allowed_uid, served.as_ref());
    });
    let privileged = PrivilegedClient::new(socket);

    let worker = std::thread::spawn(move || {
        super::update_routes::complete_runtime_update(
            &privileged,
            "release-1",
            false,
            false,
            lease,
        );
    });
    // Play housekeeping while the worker polls: a lease that is not renewed is reaped here.
    while !worker.is_finished() {
        {
            let mut conn = database.lock();
            jobs.reap_expired_leases(&mut conn).unwrap();
        }
        std::thread::sleep(std::time::Duration::from_millis(50));
    }
    worker.join().unwrap();

    let (state, error_code): (String, Option<String>) = database
        .lock()
        .query_row(
            "SELECT state, error_code FROM operations WHERE id = ?1",
            [operation.to_string()],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .unwrap();
    assert!(
        backend.polls.load(Ordering::SeqCst) >= 4,
        "the helper was polled to completion"
    );
    assert_eq!((state.as_str(), error_code.as_deref()), ("succeeded", None));
}
