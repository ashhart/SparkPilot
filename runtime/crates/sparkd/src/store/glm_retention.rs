use super::*;

#[test]
fn extreme_retention_values_do_not_panic_or_delete_usage() {
    let conn = Connection::open_in_memory().unwrap();
    conn.execute_batch("CREATE TABLE usage_daily(day TEXT NOT NULL); INSERT INTO usage_daily VALUES ('2020-01-01');").unwrap();
    assert_eq!(
        prune_usage_daily(&conn, "2026-09-05T04:00:00Z", u64::MAX).unwrap(),
        0
    );
}

#[test]
fn expired_pairing_challenge_lookup_uses_an_index() {
    let mut conn = Connection::open_in_memory().unwrap();
    crate::migration::migrate(&mut conn).unwrap();
    let detail: String = conn.query_row("EXPLAIN QUERY PLAN SELECT rowid FROM pairing_challenges WHERE expires_at <= '2026-09-05T04:00:00Z' ORDER BY expires_at LIMIT 1000", [], |row| row.get(3)).unwrap();
    assert!(
        detail.contains("INDEX"),
        "expiry sweep scans abandoned challenges: {detail}"
    );
}
#[test]
fn expires_old_rows_without_removing_current_challenges_or_receipts() {
    let conn = Connection::open_in_memory().unwrap();
    conn.execute_batch("CREATE TABLE idempotency_records(expires_at TEXT); CREATE TABLE pairing_challenges(expires_at TEXT);").unwrap();
    for table in ["idempotency_records", "pairing_challenges"] {
        for date in [
            "2026-09-03T00:00:00Z",
            "2026-09-04T00:00:00Z",
            "2026-09-05T00:00:00Z",
        ] {
            conn.execute(&format!("INSERT INTO {table} VALUES (?1)"), [date])
                .unwrap();
        }
    }
    assert_eq!(
        prune_expired_records(&conn, "2026-09-04T00:00:00Z").unwrap(),
        4
    );
    assert_eq!(
        prune_expired_records(&conn, "2026-09-04T00:00:00Z").unwrap(),
        0
    );
    for table in ["idempotency_records", "pairing_challenges"] {
        let remaining: String = conn
            .query_row(&format!("SELECT expires_at FROM {table}"), [], |r| r.get(0))
            .unwrap();
        assert_eq!(remaining, "2026-09-05T00:00:00Z");
    }
}

#[test]
fn aggregated_usage_is_forgotten_after_its_retention_window() {
    let conn = Connection::open_in_memory().unwrap();
    conn.execute_batch("CREATE TABLE usage_daily(day TEXT NOT NULL, device_id TEXT NOT NULL);")
        .unwrap();
    for day in ["2026-05-01", "2026-06-06", "2026-06-07", "2026-09-05"] {
        conn.execute("INSERT INTO usage_daily VALUES (?1, 'd')", [day])
            .unwrap();
    }
    // 90 days before 2026-09-05 is 2026-06-07; that day is kept, everything older is not.
    assert_eq!(
        prune_usage_daily(&conn, "2026-09-05T04:00:00Z", 90).unwrap(),
        2
    );
    assert_eq!(
        prune_usage_daily(&conn, "2026-09-05T04:00:00Z", 90).unwrap(),
        0
    );
    let remaining: Vec<String> = conn
        .prepare("SELECT day FROM usage_daily ORDER BY day")
        .unwrap()
        .query_map([], |row| row.get(0))
        .unwrap()
        .map(Result::unwrap)
        .collect();
    assert_eq!(remaining, vec!["2026-06-07", "2026-09-05"]);
    // Retention off keeps everything.
    assert_eq!(
        prune_usage_daily(&conn, "2026-09-05T04:00:00Z", 0).unwrap(),
        0
    );
}
