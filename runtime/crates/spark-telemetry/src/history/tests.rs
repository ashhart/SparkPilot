use super::*;

const SCHEMA: &str = include_str!("../../../sparkd/migrations/0017_telemetry_history.sql");
/// On a minute boundary, so six ten-second samples are exactly one minute.
const BASE: i64 = 1_000_000_020;

fn db() -> Connection {
    let conn = Connection::open_in_memory().expect("open");
    conn.execute_batch(SCHEMA).expect("schema");
    conn
}

fn sample(cpu: f64) -> TelemetrySample {
    TelemetrySample {
        cpu_utilisation: Some(cpu),
        memory_total_bytes: Some(128 * 1024 * 1024 * 1024),
        memory_available_bytes: Some(64 * 1024 * 1024 * 1024),
        memory_pressure: Some("normal".to_owned()),
        active_requests: Some(2),
        queue_depth: Some(1),
        ..TelemetrySample::default()
    }
}

fn after_raw_window() -> i64 {
    BASE + DEFAULT_RAW_RETENTION_SECONDS + MINUTE_BUCKET_SECONDS
}

fn compact_now(conn: &mut Connection, now: i64) -> CompactionOutcome {
    compact(
        conn,
        now,
        DEFAULT_RAW_RETENTION_SECONDS,
        DEFAULT_AGGREGATE_RETENTION_SECONDS,
    )
    .expect("compact")
}

fn all(conn: &Connection) -> Vec<HistoryRow> {
    history(conn, 0, i64::MAX, 100).expect("history")
}

#[test]
fn samples_land_in_ten_second_buckets() {
    let conn = db();
    assert_eq!(record_sample(&conn, BASE, &sample(0.1)).unwrap(), BASE);
    assert_eq!(record_sample(&conn, BASE + 9, &sample(0.2)).unwrap(), BASE);
    assert_eq!(
        record_sample(&conn, BASE + 10, &sample(0.3)).unwrap(),
        BASE + 10
    );
    assert_eq!(
        all(&conn).len(),
        2,
        "a second sample in one bucket made a second row"
    );
}

#[test]
fn a_duplicate_bucket_replaces_rather_than_accumulates() {
    let conn = db();
    record_sample(&conn, BASE, &sample(0.1)).unwrap();
    record_sample(&conn, BASE + 5, &sample(0.9)).unwrap();
    let rows = all(&conn);
    assert_eq!(rows.len(), 1);
    assert_eq!(
        rows[0].cpu_utilisation,
        Some(0.9),
        "the later reading did not win"
    );
    assert_eq!(rows[0].sample_count, 1);
}

#[test]
fn a_clock_that_steps_backwards_writes_an_earlier_bucket_not_a_broken_one() {
    let conn = db();
    record_sample(&conn, BASE + 100, &sample(0.5)).unwrap();
    let bucket = record_sample(&conn, BASE + 40, &sample(0.4)).unwrap();
    assert_eq!(bucket, BASE + 40);
    let rows = all(&conn);
    assert_eq!(rows.len(), 2);
    assert!(rows[0].bucket_start > rows[1].bucket_start, "newest first");
    assert_eq!(bucket_of(-5, 10), -10);
}

#[test]
fn a_late_sample_still_lands_in_the_bucket_it_belongs_to() {
    let conn = db();
    record_sample(&conn, BASE + 30, &sample(0.3)).unwrap();
    record_sample(&conn, BASE + 12, &sample(0.2)).unwrap();
    assert_eq!(
        all(&conn)
            .iter()
            .map(|row| row.bucket_start)
            .collect::<Vec<_>>(),
        [BASE + 30, BASE + 10]
    );
}

/// A late seventh sample must coexist with the six-sample minute, then merge into it without replacing its history.
#[test]
fn a_sample_arriving_after_its_minute_was_folded_joins_it_rather_than_replacing_it() {
    let mut conn = db();
    for step in 0..6 {
        record_sample(&conn, BASE + step * RAW_BUCKET_SECONDS, &sample(0.2)).unwrap();
    }
    compact_now(&mut conn, after_raw_window());
    let folded = all(&conn);
    assert_eq!(folded.len(), 1);
    assert_eq!(folded[0].sample_count, 6);
    assert!((folded[0].cpu_utilisation.unwrap() - 0.2).abs() < 1e-9);

    // Late, for a minute that no longer has raw rows.
    record_sample(&conn, BASE + 20, &sample(0.8)).unwrap();

    // Expose both the existing aggregate and late raw reading before compaction so the chart loses no samples.
    let between = all(&conn);
    let minute = between
        .iter()
        .find(|row| row.resolution == "minute")
        .expect("the folded minute disappeared behind a late sample");
    assert_eq!(minute.sample_count, 6);
    assert!(
        between.iter().any(|row| row.resolution == "raw"),
        "the late sample is not visible"
    );

    // After: one minute holding all seven, with the mean of all seven.
    compact_now(&mut conn, after_raw_window() + MINUTE_BUCKET_SECONDS);
    let merged = all(&conn);
    assert_eq!(merged.len(), 1, "the merge produced more than one minute");
    assert_eq!(merged[0].sample_count, 7, "the prior six were lost");
    let expected = (0.2 * 6.0 + 0.8) / 7.0;
    assert!(
        (merged[0].cpu_utilisation.unwrap() - expected).abs() < 1e-9,
        "got {:?}, expected the mean of all seven",
        merged[0].cpu_utilisation
    );
}

/// Compaction with nothing new to fold must not change a merged minute.
#[test]
fn re_running_compaction_after_a_merge_changes_nothing() {
    let mut conn = db();
    for step in 0..6 {
        record_sample(&conn, BASE + step * RAW_BUCKET_SECONDS, &sample(0.2)).unwrap();
    }
    compact_now(&mut conn, after_raw_window());
    record_sample(&conn, BASE + 20, &sample(0.8)).unwrap();
    compact_now(&mut conn, after_raw_window() + MINUTE_BUCKET_SECONDS);
    let once = all(&conn);
    for _ in 0..3 {
        let outcome = compact_now(&mut conn, after_raw_window() + MINUTE_BUCKET_SECONDS);
        assert_eq!(outcome.minutes_written, 0);
        assert_eq!(outcome.raw_removed, 0);
    }
    assert_eq!(all(&conn), once, "a repeat compaction changed the history");
}

#[test]
fn compaction_folds_old_raw_into_minutes_and_is_idempotent() {
    let mut conn = db();
    for step in 0..6 {
        record_sample(
            &conn,
            BASE + step * RAW_BUCKET_SECONDS,
            &sample(0.1 * step as f64),
        )
        .unwrap();
    }
    let first = compact_now(&mut conn, after_raw_window());
    assert_eq!(first.minutes_written, 1);
    assert_eq!(first.raw_removed, 6);

    let rows = all(&conn);
    assert_eq!(rows.len(), 1);
    assert_eq!(rows[0].resolution, "minute");
    assert_eq!(rows[0].sample_count, 6);
    let mean = (0..6).map(|s| 0.1 * s as f64).sum::<f64>() / 6.0;
    assert!((rows[0].cpu_utilisation.unwrap() - mean).abs() < 1e-9);

    let again = compact_now(&mut conn, after_raw_window());
    assert_eq!(again.minutes_written, 0, "a second run re-folded nothing");
    assert_eq!(again.raw_removed, 0);
    assert_eq!(all(&conn).len(), 1);
}

#[test]
fn compaction_leaves_the_raw_window_alone() {
    let mut conn = db();
    let now = BASE + DEFAULT_RAW_RETENTION_SECONDS;
    record_sample(&conn, now - 60, &sample(0.4)).unwrap();
    let outcome = compact_now(&mut conn, now);
    assert_eq!(outcome.minutes_written, 0);
    assert_eq!(outcome.raw_removed, 0);
    assert_eq!(all(&conn)[0].resolution, "raw");
}

#[test]
fn aggregates_past_their_window_are_dropped() {
    let mut conn = db();
    record_sample(&conn, BASE, &sample(0.5)).unwrap();
    compact_now(&mut conn, after_raw_window());
    assert_eq!(all(&conn).len(), 1);

    let outcome = compact_now(&mut conn, BASE + DEFAULT_AGGREGATE_RETENTION_SECONDS + 1);
    assert_eq!(outcome.aggregates_removed, 1);
    assert!(all(&conn).is_empty());
}

#[test]
fn a_failed_compaction_leaves_the_history_as_it_was() {
    let mut conn = db();
    for step in 0..6 {
        record_sample(&conn, BASE + step * RAW_BUCKET_SECONDS, &sample(0.2)).unwrap();
    }
    conn.execute_batch("DROP TABLE telemetry_minutes").unwrap();
    assert!(
        compact(
            &mut conn,
            after_raw_window(),
            DEFAULT_RAW_RETENTION_SECONDS,
            DEFAULT_AGGREGATE_RETENTION_SECONDS
        )
        .is_err()
    );
    let remaining: i64 = conn
        .query_row("SELECT COUNT(*) FROM telemetry_samples", [], |row| {
            row.get(0)
        })
        .unwrap();
    assert_eq!(
        remaining, 6,
        "raw samples were dropped without an aggregate"
    );
}

#[test]
fn a_delete_that_fails_after_a_successful_fold_rolls_the_whole_thing_back() {
    let mut conn = db();
    for step in 0..6 {
        record_sample(&conn, BASE + step * RAW_BUCKET_SECONDS, &sample(0.2)).unwrap();
    }
    conn.execute_batch(
        "CREATE TRIGGER refuse_delete BEFORE DELETE ON telemetry_samples
         BEGIN SELECT RAISE(ABORT, 'deletion refused'); END;",
    )
    .unwrap();
    assert!(
        compact(
            &mut conn,
            after_raw_window(),
            DEFAULT_RAW_RETENTION_SECONDS,
            DEFAULT_AGGREGATE_RETENTION_SECONDS
        )
        .is_err(),
        "a refused delete was reported as a successful compaction"
    );
    let minutes: i64 = conn
        .query_row("SELECT COUNT(*) FROM telemetry_minutes", [], |row| {
            row.get(0)
        })
        .unwrap();
    assert_eq!(
        minutes, 0,
        "a minute was committed without its raw rows being removed"
    );
}

#[test]
fn a_request_for_more_rows_than_the_cap_is_clamped_to_it() {
    let conn = db();
    for step in 0..(MAX_HISTORY_ROWS as i64 + 5) {
        record_sample(&conn, BASE + step * RAW_BUCKET_SECONDS, &sample(0.1)).unwrap();
    }
    assert_eq!(
        history(&conn, 0, i64::MAX, usize::MAX).unwrap().len(),
        MAX_HISTORY_ROWS,
        "the cap on returned rows was not applied"
    );
}

#[test]
fn history_reports_raw_and_aggregate_apart_and_respects_its_limit() {
    let mut conn = db();
    for step in 0..6 {
        record_sample(&conn, BASE + step * RAW_BUCKET_SECONDS, &sample(0.2)).unwrap();
    }
    let now = after_raw_window();
    compact_now(&mut conn, now);
    for step in 0..3 {
        record_sample(&conn, now + step * RAW_BUCKET_SECONDS, &sample(0.7)).unwrap();
    }
    assert_eq!(
        all(&conn)
            .iter()
            .map(|row| row.resolution)
            .collect::<Vec<_>>(),
        ["raw", "raw", "raw", "minute"]
    );
    assert_eq!(history(&conn, 0, i64::MAX, 2).unwrap().len(), 2);
}

#[test]
fn a_range_returns_only_what_falls_inside_it() {
    let conn = db();
    for step in 0..5 {
        record_sample(&conn, BASE + step * RAW_BUCKET_SECONDS, &sample(0.1)).unwrap();
    }
    assert_eq!(
        history(&conn, BASE + 10, BASE + 30, 100)
            .unwrap()
            .iter()
            .map(|row| row.bucket_start)
            .collect::<Vec<_>>(),
        [BASE + 30, BASE + 20, BASE + 10]
    );
}

#[test]
fn withdrawing_consent_removes_every_recorded_sample() {
    let mut conn = db();
    record_sample(&conn, BASE, &sample(0.5)).unwrap();
    compact_now(&mut conn, after_raw_window());
    record_sample(&conn, after_raw_window() + 120, &sample(0.6)).unwrap();
    assert!(!all(&conn).is_empty());
    purge(&conn).unwrap();
    assert!(all(&conn).is_empty());
    assert_eq!(latest_bucket(&conn).unwrap(), None);
}

/// Verify the database rejects unsupported pressure vocabulary.
#[test]
fn the_database_refuses_free_text_in_the_one_vocabulary_field() {
    let conn = db();
    for hostile in [
        "what is my bank balance",
        "sk-live-4f3a",
        "/var/lib/spark-runtime/state.db",
        "192.168.1.44",
        "normal; DROP TABLE telemetry_samples",
        "",
    ] {
        let refused = conn.execute(
            "INSERT INTO telemetry_samples (bucket_start, memory_pressure) VALUES (?1, ?2)",
            params![BASE + 1_000, hostile],
        );
        assert!(
            refused.is_err(),
            "the database accepted {hostile:?} as a memory pressure"
        );
    }
    // The sanitizer must discard unknown tokens before persistence.
    record_sample(
        &conn,
        BASE,
        &TelemetrySample {
            memory_pressure: Some("catastrophic".to_owned()),
            ..TelemetrySample::default()
        },
    )
    .expect("an unknown token must not fail the write");
    assert_eq!(all(&conn)[0].memory_pressure, None);
}

/// Verify no history column accepts arbitrary text.
#[test]
fn no_history_column_holds_free_text() {
    let conn = db();
    for table in ["telemetry_samples", "telemetry_minutes"] {
        let mut statement = conn
            .prepare(&format!("PRAGMA table_info({table})"))
            .unwrap();
        let columns: Vec<(String, String)> = statement
            .query_map([], |row| Ok((row.get(1)?, row.get(2)?)))
            .unwrap()
            .collect::<rusqlite::Result<_>>()
            .unwrap();
        for (name, kind) in columns {
            assert!(
                kind != "TEXT" || name == "memory_pressure",
                "{table}.{name} is free text in the telemetry history"
            );
        }
    }
}

#[test]
fn an_unreported_value_stays_missing_rather_than_becoming_zero() {
    let mut conn = db();
    record_sample(&conn, BASE, &TelemetrySample::default()).unwrap();
    let raw = all(&conn);
    assert_eq!(raw[0].cpu_utilisation, None);
    assert_eq!(raw[0].temperature_celsius, None);

    // An unreported field keeps count zero after compaction and reads back as unavailable.
    compact_now(&mut conn, after_raw_window());
    let folded = all(&conn);
    assert_eq!(folded[0].resolution, "minute");
    assert_eq!(folded[0].cpu_utilisation, None);
    assert_eq!(folded[0].temperature_celsius, None);
    assert_eq!(folded[0].memory_pressure, None);
}

/// A field only some samples reported is the mean of those, not of all.
#[test]
fn a_partly_reported_field_averages_only_the_readings_that_had_it() {
    let mut conn = db();
    record_sample(
        &conn,
        BASE,
        &TelemetrySample {
            temperature_celsius: Some(40.0),
            ..TelemetrySample::default()
        },
    )
    .unwrap();
    record_sample(&conn, BASE + 10, &TelemetrySample::default()).unwrap();
    record_sample(
        &conn,
        BASE + 20,
        &TelemetrySample {
            temperature_celsius: Some(50.0),
            ..TelemetrySample::default()
        },
    )
    .unwrap();
    compact_now(&mut conn, after_raw_window());
    let folded = all(&conn);
    assert_eq!(folded[0].sample_count, 3);
    assert_eq!(
        folded[0].temperature_celsius,
        Some(45.0),
        "divided by three, not two"
    );
}

/// Retain the worst pressure observed within the minute.
#[test]
fn a_merged_minute_keeps_the_worst_pressure_it_saw() {
    let mut conn = db();
    record_sample(
        &conn,
        BASE,
        &TelemetrySample {
            memory_pressure: Some("critical".to_owned()),
            ..TelemetrySample::default()
        },
    )
    .unwrap();
    compact_now(&mut conn, after_raw_window());
    record_sample(
        &conn,
        BASE + 10,
        &TelemetrySample {
            memory_pressure: Some("normal".to_owned()),
            ..TelemetrySample::default()
        },
    )
    .unwrap();
    compact_now(&mut conn, after_raw_window() + MINUTE_BUCKET_SECONDS);
    assert_eq!(all(&conn)[0].memory_pressure.as_deref(), Some("critical"));
}

#[test]
fn a_restart_continues_the_series_rather_than_starting_a_new_one() {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("runtime.db");
    {
        let conn = Connection::open(&path).unwrap();
        conn.execute_batch(SCHEMA).unwrap();
        record_sample(&conn, BASE, &sample(0.1)).unwrap();
    }
    let conn = Connection::open(&path).unwrap();
    record_sample(&conn, BASE + RAW_BUCKET_SECONDS, &sample(0.2)).unwrap();
    assert_eq!(
        all(&conn).len(),
        2,
        "the series restarted instead of continuing"
    );
    assert_eq!(
        latest_bucket(&conn).unwrap(),
        Some(BASE + RAW_BUCKET_SECONDS)
    );
}
