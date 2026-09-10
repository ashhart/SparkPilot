//! Require atomic nonce admission so concurrent copies cannot both execute one captured signed mutation.

use std::sync::Arc;

use parking_lot::Mutex;
use rusqlite::Connection;
use sparkd::store::NonceAdmission;
use uuid::Uuid;

const ADMITTED_AT: &str = "2026-01-01T00:00:00Z";
const EXPIRES_AT: &str = "2099-01-01T00:00:00Z";

fn migrated(conn: &mut Connection) -> uuid::Uuid {
    sparkd::migration::migrate(conn).unwrap();
    let device = Uuid::new_v4();
    sparkd::store::insert_device(conn, &device, "mac", "macos", &[1, 2, 3], "fp", "owner").unwrap();
    device
}

#[test]
fn second_admission_of_the_same_nonce_is_a_replay() {
    let mut conn = Connection::open_in_memory().unwrap();
    let device = migrated(&mut conn);
    let nonce: [u8; 32] = [7; 32];

    let first =
        sparkd::store::admit_request_nonce(&mut conn, &device, &nonce, ADMITTED_AT, EXPIRES_AT)
            .unwrap();
    let second =
        sparkd::store::admit_request_nonce(&mut conn, &device, &nonce, ADMITTED_AT, EXPIRES_AT)
            .unwrap();

    assert_eq!(first, NonceAdmission::Admitted);
    assert_eq!(second, NonceAdmission::Replayed);
}

#[test]
fn racing_admissions_admit_exactly_one() {
    let mut conn = Connection::open_in_memory().unwrap();
    let device = migrated(&mut conn);
    let db = Arc::new(Mutex::new(conn));
    let nonce: [u8; 32] = [9; 32];
    let wins = Arc::new(std::sync::atomic::AtomicUsize::new(0));

    let mut joins = Vec::new();
    for _ in 0..8 {
        let db = db.clone();
        let wins = wins.clone();
        joins.push(std::thread::spawn(move || {
            let mut conn = db.lock();
            let admission = sparkd::store::admit_request_nonce(
                &mut conn,
                &device,
                &nonce,
                ADMITTED_AT,
                EXPIRES_AT,
            )
            .unwrap();
            if admission == NonceAdmission::Admitted {
                wins.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            }
        }));
    }
    for join in joins {
        join.join().unwrap();
    }

    assert_eq!(
        wins.load(std::sync::atomic::Ordering::SeqCst),
        1,
        "exactly one admission may win"
    );
}

#[test]
fn admitted_activity_is_persisted_at_most_once_per_minute_and_replays_never_refresh_it() {
    let mut conn = Connection::open_in_memory().unwrap();
    let device = migrated(&mut conn);
    let seen = |conn: &Connection| {
        sparkd::store::device_row(conn, &device)
            .unwrap()
            .unwrap()
            .last_seen_at
    };
    sparkd::store::admit_request_nonce(&mut conn, &device, &[1; 32], ADMITTED_AT, EXPIRES_AT)
        .unwrap();
    assert_eq!(seen(&conn).as_deref(), Some(ADMITTED_AT));
    sparkd::store::admit_request_nonce(
        &mut conn,
        &device,
        &[2; 32],
        "2026-01-01T00:00:59Z",
        EXPIRES_AT,
    )
    .unwrap();
    assert_eq!(
        seen(&conn).as_deref(),
        Some(ADMITTED_AT),
        "frequent telemetry does not rewrite the device row"
    );
    sparkd::store::admit_request_nonce(
        &mut conn,
        &device,
        &[3; 32],
        "2026-01-01T00:01:00Z",
        EXPIRES_AT,
    )
    .unwrap();
    assert_eq!(seen(&conn).as_deref(), Some("2026-01-01T00:01:00Z"));
    let replay = sparkd::store::admit_request_nonce(
        &mut conn,
        &device,
        &[1; 32],
        "2026-01-01T00:02:00Z",
        EXPIRES_AT,
    )
    .unwrap();
    assert_eq!(replay, NonceAdmission::Replayed);
    assert_eq!(seen(&conn).as_deref(), Some("2026-01-01T00:01:00Z"));
}
