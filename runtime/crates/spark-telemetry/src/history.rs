//! Record ten-second numeric samples and compact to minutes; bounded vocabulary excludes prompts, paths and addresses.

use rusqlite::{Connection, OptionalExtension, params};

/// The width of a raw sample bucket, in seconds.
pub const RAW_BUCKET_SECONDS: i64 = 10;
/// The width of an aggregate bucket, in seconds.
pub const MINUTE_BUCKET_SECONDS: i64 = 60;
/// How long raw samples are kept before compaction.
pub const DEFAULT_RAW_RETENTION_SECONDS: i64 = 24 * 60 * 60;
/// How long one-minute aggregates are kept.
pub const DEFAULT_AGGREGATE_RETENTION_SECONDS: i64 = 30 * 24 * 60 * 60;
/// The most rows one history request may return.
pub const MAX_HISTORY_ROWS: usize = 2_880;

/// The memory-pressure vocabulary, worst last. Stored as the index.
const PRESSURE: [&str; 4] = ["normal", "warning", "critical", "emergency"];

fn pressure_rank(name: &str) -> Option<i64> {
    PRESSURE
        .iter()
        .position(|known| *known == name)
        .map(|index| index as i64)
}

fn pressure_name(rank: i64) -> Option<String> {
    usize::try_from(rank)
        .ok()
        .and_then(|index| PRESSURE.get(index))
        .map(|name| (*name).to_owned())
}

/// Optional fields distinguish unavailable readings from measured zero.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct TelemetrySample {
    pub cpu_utilisation: Option<f64>,
    pub load_average_1m: Option<f64>,
    pub memory_total_bytes: Option<i64>,
    pub memory_available_bytes: Option<i64>,
    pub memory_pressure: Option<String>,
    pub temperature_celsius: Option<f64>,
    pub accelerator_utilisation: Option<f64>,
    pub accelerator_memory_used_bytes: Option<i64>,
    pub accelerator_memory_total_bytes: Option<i64>,
    pub active_requests: Option<i64>,
    pub queue_depth: Option<i64>,
    pub tokens_per_second: Option<f64>,
    pub time_to_first_token_ms: Option<f64>,
}

/// A history row as a client sees it.
#[derive(Debug, Clone, PartialEq)]
pub struct HistoryRow {
    pub bucket_start: i64,
    pub observed_at: String,
    /// `"raw"` for a ten-second sample, `"minute"` for an aggregate.
    pub resolution: &'static str,
    /// How many raw samples this row represents. Always 1 for raw.
    pub sample_count: i64,
    pub cpu_utilisation: Option<f64>,
    pub load_average_1m: Option<f64>,
    pub memory_total_bytes: Option<i64>,
    pub memory_available_bytes: Option<i64>,
    pub memory_pressure: Option<String>,
    pub temperature_celsius: Option<f64>,
    pub accelerator_utilisation: Option<f64>,
    pub accelerator_memory_used_bytes: Option<i64>,
    pub accelerator_memory_total_bytes: Option<i64>,
    pub active_requests: Option<f64>,
    pub queue_depth: Option<f64>,
    pub tokens_per_second: Option<f64>,
    pub time_to_first_token_ms: Option<f64>,
}

/// Floor instants into buckets, including negative Unix timestamps and backward clock steps.
pub fn bucket_of(unix_seconds: i64, width: i64) -> i64 {
    unix_seconds.div_euclid(width) * width
}

/// Derive timestamps from numeric buckets so history needs no free-text timestamp column.
pub fn observed_at(unix_seconds: i64) -> String {
    time::OffsetDateTime::from_unix_timestamp(unix_seconds)
        .unwrap_or(time::OffsetDateTime::UNIX_EPOCH)
        .format(&time::format_description::well_known::Rfc3339)
        .unwrap_or_else(|_| "1970-01-01T00:00:00Z".to_owned())
}

/// Replace the same ten-second bucket on retry or overlapping timers instead of inflating sample counts.
pub fn record_sample(
    conn: &Connection,
    unix_seconds: i64,
    sample: &TelemetrySample,
) -> rusqlite::Result<i64> {
    let bucket = bucket_of(unix_seconds, RAW_BUCKET_SECONDS);
    let pressure = sample
        .memory_pressure
        .as_deref()
        .and_then(pressure_rank)
        .and_then(pressure_name);
    conn.execute(
        "INSERT INTO telemetry_samples
            (bucket_start, cpu_utilisation, load_average_1m,
             memory_total_bytes, memory_available_bytes, memory_pressure,
             temperature_celsius, accelerator_utilisation,
             accelerator_memory_used_bytes, accelerator_memory_total_bytes,
             active_requests, queue_depth, tokens_per_second,
             time_to_first_token_ms)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14)
         ON CONFLICT (bucket_start) DO UPDATE SET
            cpu_utilisation = excluded.cpu_utilisation,
            load_average_1m = excluded.load_average_1m,
            memory_total_bytes = excluded.memory_total_bytes,
            memory_available_bytes = excluded.memory_available_bytes,
            memory_pressure = excluded.memory_pressure,
            temperature_celsius = excluded.temperature_celsius,
            accelerator_utilisation = excluded.accelerator_utilisation,
            accelerator_memory_used_bytes = excluded.accelerator_memory_used_bytes,
            accelerator_memory_total_bytes = excluded.accelerator_memory_total_bytes,
            active_requests = excluded.active_requests,
            queue_depth = excluded.queue_depth,
            tokens_per_second = excluded.tokens_per_second,
            time_to_first_token_ms = excluded.time_to_first_token_ms",
        params![
            bucket,
            sample.cpu_utilisation,
            sample.load_average_1m,
            sample.memory_total_bytes,
            sample.memory_available_bytes,
            pressure,
            sample.temperature_celsius,
            sample.accelerator_utilisation,
            sample.accelerator_memory_used_bytes,
            sample.accelerator_memory_total_bytes,
            sample.active_requests,
            sample.queue_depth,
            sample.tokens_per_second,
            sample.time_to_first_token_ms,
        ],
    )?;
    Ok(bucket)
}

/// The fields folded as a mean, and the raw column each comes from.
const MEANS: [&str; 10] = [
    "cpu_utilisation",
    "load_average_1m",
    "memory_available_bytes",
    "temperature_celsius",
    "accelerator_utilisation",
    "accelerator_memory_used_bytes",
    "active_requests",
    "queue_depth",
    "tokens_per_second",
    "time_to_first_token_ms",
];

/// Atomically merge expired raw rows into minute sums/counts and delete them, including late samples exactly once.
pub fn compact(
    conn: &mut Connection,
    now_unix: i64,
    raw_retention_seconds: i64,
    aggregate_retention_seconds: i64,
) -> rusqlite::Result<CompactionOutcome> {
    // Use the exact retention cutoff; weighted merging permits partially folded minutes without retaining an extra 59 seconds.
    let raw_cutoff = now_unix.saturating_sub(raw_retention_seconds);
    let aggregate_cutoff = now_unix.saturating_sub(aggregate_retention_seconds);

    let mut columns = vec!["bucket_start".to_owned(), "sample_count".to_owned()];
    let mut selects = vec![
        format!("(bucket_start / {MINUTE_BUCKET_SECONDS}) * {MINUTE_BUCKET_SECONDS}"),
        "COUNT(*)".to_owned(),
    ];
    let mut updates = vec!["sample_count = sample_count + excluded.sample_count".to_owned()];
    for field in MEANS {
        columns.push(format!("{field}_sum"));
        selects.push(format!("COALESCE(SUM({field}), 0)"));
        updates.push(format!("{field}_sum = {field}_sum + excluded.{field}_sum"));
        columns.push(format!("{field}_n"));
        selects.push(format!("COUNT({field})"));
        updates.push(format!("{field}_n = {field}_n + excluded.{field}_n"));
    }
    for field in ["memory_total_bytes", "accelerator_memory_total_bytes"] {
        columns.push(format!("{field}_max"));
        selects.push(format!("MAX({field})"));
        updates.push(format!(
            "{field}_max = MAX(COALESCE({field}_max, excluded.{field}_max), \
             COALESCE(excluded.{field}_max, {field}_max))"
        ));
    }
    columns.push("memory_pressure_rank".to_owned());
    selects.push(format!(
        "MAX(CASE memory_pressure {} END)",
        PRESSURE
            .iter()
            .enumerate()
            .map(|(rank, name)| format!("WHEN '{name}' THEN {rank}"))
            .collect::<Vec<_>>()
            .join(" ")
    ));
    updates.push(
        "memory_pressure_rank = MAX(\
         COALESCE(memory_pressure_rank, excluded.memory_pressure_rank), \
         COALESCE(excluded.memory_pressure_rank, memory_pressure_rank))"
            .to_owned(),
    );

    let fold = format!(
        "INSERT INTO telemetry_minutes ({})
         SELECT {}
         FROM telemetry_samples
         WHERE bucket_start < ?1
         GROUP BY (bucket_start / {MINUTE_BUCKET_SECONDS})
         ON CONFLICT (bucket_start) DO UPDATE SET {}",
        columns.join(", "),
        selects.join(", "),
        updates.join(", ")
    );

    let tx = conn.transaction()?;
    let minutes = tx.execute(&fold, params![raw_cutoff])?;
    let raw_removed = tx.execute(
        "DELETE FROM telemetry_samples WHERE bucket_start < ?1",
        params![raw_cutoff],
    )?;
    let aggregates_removed = tx.execute(
        "DELETE FROM telemetry_minutes WHERE bucket_start < ?1",
        params![aggregate_cutoff],
    )?;
    tx.commit()?;
    Ok(CompactionOutcome {
        minutes_written: minutes,
        raw_removed,
        aggregates_removed,
    })
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct CompactionOutcome {
    pub minutes_written: usize,
    pub raw_removed: usize,
    pub aggregates_removed: usize,
}

/// Read [from, to] newest first, combining raw and aggregate evidence without suppressing a minute for a late sample.
pub fn history(
    conn: &Connection,
    from_unix: i64,
    to_unix: i64,
    limit: usize,
) -> rusqlite::Result<Vec<HistoryRow>> {
    let limit = limit.min(MAX_HISTORY_ROWS);
    let mut rows = Vec::new();
    let mut raw = conn.prepare(
        "SELECT bucket_start, cpu_utilisation, load_average_1m,
                memory_total_bytes, memory_available_bytes, memory_pressure,
                temperature_celsius, accelerator_utilisation,
                accelerator_memory_used_bytes, accelerator_memory_total_bytes,
                active_requests, queue_depth, tokens_per_second, time_to_first_token_ms
         FROM telemetry_samples
         WHERE bucket_start BETWEEN ?1 AND ?2
         ORDER BY bucket_start DESC LIMIT ?3",
    )?;
    for row in raw.query_map(params![from_unix, to_unix, limit as i64], |row| {
        let bucket: i64 = row.get(0)?;
        Ok(HistoryRow {
            bucket_start: bucket,
            observed_at: observed_at(bucket),
            resolution: "raw",
            sample_count: 1,
            cpu_utilisation: row.get(1)?,
            load_average_1m: row.get(2)?,
            memory_total_bytes: row.get(3)?,
            memory_available_bytes: row.get(4)?,
            memory_pressure: row.get(5)?,
            temperature_celsius: row.get(6)?,
            accelerator_utilisation: row.get(7)?,
            accelerator_memory_used_bytes: row.get(8)?,
            accelerator_memory_total_bytes: row.get(9)?,
            active_requests: row.get::<_, Option<f64>>(10)?,
            queue_depth: row.get::<_, Option<f64>>(11)?,
            tokens_per_second: row.get(12)?,
            time_to_first_token_ms: row.get(13)?,
        })
    })? {
        rows.push(row?);
    }
    let remaining = limit.saturating_sub(rows.len());
    if remaining == 0 {
        return Ok(rows);
    }
    // Compaction deletes folded rows, so remaining raw rows and minute aggregates represent disjoint readings.
    let mut minutes = conn.prepare(
        "SELECT bucket_start, sample_count,
                cpu_utilisation_sum, cpu_utilisation_n,
                load_average_1m_sum, load_average_1m_n,
                memory_available_bytes_sum, memory_available_bytes_n,
                temperature_celsius_sum, temperature_celsius_n,
                accelerator_utilisation_sum, accelerator_utilisation_n,
                accelerator_memory_used_bytes_sum, accelerator_memory_used_bytes_n,
                active_requests_sum, active_requests_n,
                queue_depth_sum, queue_depth_n,
                tokens_per_second_sum, tokens_per_second_n,
                time_to_first_token_ms_sum, time_to_first_token_ms_n,
                memory_total_bytes_max, accelerator_memory_total_bytes_max,
                memory_pressure_rank
         FROM telemetry_minutes
         WHERE bucket_start BETWEEN ?1 AND ?2
         ORDER BY bucket_start DESC",
    )?;
    let folded = minutes.query_map(params![from_unix, to_unix], |row| {
        let bucket: i64 = row.get(0)?;
        let mean =
            |sum: usize, count: usize, row: &rusqlite::Row<'_>| -> rusqlite::Result<Option<f64>> {
                let total: f64 = row.get(sum)?;
                let n: i64 = row.get(count)?;
                Ok((n > 0).then(|| total / n as f64))
            };
        Ok(HistoryRow {
            bucket_start: bucket,
            observed_at: observed_at(bucket),
            resolution: "minute",
            sample_count: row.get(1)?,
            cpu_utilisation: mean(2, 3, row)?,
            load_average_1m: mean(4, 5, row)?,
            memory_available_bytes: mean(6, 7, row)?.map(|value| value.round() as i64),
            temperature_celsius: mean(8, 9, row)?,
            accelerator_utilisation: mean(10, 11, row)?,
            accelerator_memory_used_bytes: mean(12, 13, row)?.map(|value| value.round() as i64),
            active_requests: mean(14, 15, row)?,
            queue_depth: mean(16, 17, row)?,
            tokens_per_second: mean(18, 19, row)?,
            time_to_first_token_ms: mean(20, 21, row)?,
            memory_total_bytes: row.get(22)?,
            accelerator_memory_total_bytes: row.get(23)?,
            memory_pressure: row.get::<_, Option<i64>>(24)?.and_then(pressure_name),
        })
    })?;
    for row in folded {
        rows.push(row?);
        if rows.len() >= limit {
            break;
        }
    }
    rows.sort_by(|left, right| right.bucket_start.cmp(&left.bucket_start));
    Ok(rows)
}

/// The newest bucket recorded, if any. Used to report staleness honestly.
pub fn latest_bucket(conn: &Connection) -> rusqlite::Result<Option<i64>> {
    conn.query_row(
        "SELECT MAX(bucket) FROM (
            SELECT MAX(bucket_start) AS bucket FROM telemetry_samples
            UNION ALL
            SELECT MAX(bucket_start) FROM telemetry_minutes
         )",
        [],
        |row| row.get::<_, Option<i64>>(0),
    )
    .optional()
    .map(Option::flatten)
}

/// Remove every recorded sample. Used when functional consent is withdrawn.
pub fn purge(conn: &Connection) -> rusqlite::Result<()> {
    conn.execute_batch(
        "DELETE FROM telemetry_samples;
         DELETE FROM telemetry_minutes;",
    )
}

#[cfg(test)]
#[path = "history/tests.rs"]
mod tests;
