//! Aggregate counts and tokens in usage_daily by UTC day, never prompt or response text.

use std::time::Duration;

use rusqlite::Connection;

/// One usage increment to fold into today's aggregate row.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UsageRecord {
    pub device_id: String,
    pub model_id: String,
    pub project_id: Option<String>,
    pub prompt_tokens: u64,
    pub cached_prompt_tokens: u64,
    pub generated_tokens: u64,
    pub reasoning_tokens: u64,
    pub requests: u64,
    pub failures: u64,
    pub time_to_first_token: Duration,
    pub generation_time: Duration,
}

impl UsageRecord {
    /// A single successful request's usage.
    pub fn request(
        device_id: impl Into<String>,
        model_id: impl Into<String>,
        prompt_tokens: u64,
        generated_tokens: u64,
        time_to_first_token: Duration,
        generation_time: Duration,
    ) -> Self {
        Self {
            device_id: device_id.into(),
            model_id: model_id.into(),
            project_id: None,
            prompt_tokens,
            cached_prompt_tokens: 0,
            generated_tokens,
            reasoning_tokens: 0,
            requests: 1,
            failures: 0,
            time_to_first_token,
            generation_time,
        }
    }
}

/// One aggregated `usage_daily` row.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UsageDailyRow {
    pub day: String,
    pub device_id: String,
    pub model_id: String,
    pub project_id: Option<String>,
    pub prompt_tokens: u64,
    pub cached_prompt_tokens: u64,
    pub generated_tokens: u64,
    pub reasoning_tokens: u64,
    pub requests: u64,
    pub failures: u64,
}

/// Upsert by day/device/model/project, normalizing no-project to empty string because SQLite NULL keys are distinct.
pub fn record_daily(
    conn: &Connection,
    day: &str,
    record: &UsageRecord,
) -> Result<(), rusqlite::Error> {
    conn.execute(
        "INSERT INTO usage_daily
            (day, device_id, model_id, project_id,
             prompt_tokens, cached_prompt_tokens, generated_tokens, reasoning_tokens,
             requests, failures, cumulative_ttft_ms, cumulative_generation_ms)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)
         ON CONFLICT (day, device_id, model_id, project_id) DO UPDATE SET
            prompt_tokens = prompt_tokens + excluded.prompt_tokens,
            cached_prompt_tokens = cached_prompt_tokens + excluded.cached_prompt_tokens,
            generated_tokens = generated_tokens + excluded.generated_tokens,
            reasoning_tokens = reasoning_tokens + excluded.reasoning_tokens,
            requests = requests + excluded.requests,
            failures = failures + excluded.failures,
            cumulative_ttft_ms = cumulative_ttft_ms + excluded.cumulative_ttft_ms,
            cumulative_generation_ms =
                cumulative_generation_ms + excluded.cumulative_generation_ms",
        rusqlite::params![
            day,
            record.device_id,
            record.model_id,
            // Normalise NULL project to '' so the upsert key is stable.
            record.project_id.as_deref().unwrap_or(""),
            record.prompt_tokens,
            record.cached_prompt_tokens,
            record.generated_tokens,
            record.reasoning_tokens,
            record.requests,
            record.failures,
            record.time_to_first_token.as_millis() as i64,
            record.generation_time.as_millis() as i64,
        ],
    )?;
    Ok(())
}

/// Read aggregated rows for one day, ordered for display.
pub fn daily_summary(conn: &Connection, day: &str) -> Result<Vec<UsageDailyRow>, rusqlite::Error> {
    let mut stmt = conn.prepare(
        "SELECT day, device_id, model_id, project_id,
                prompt_tokens, cached_prompt_tokens, generated_tokens, reasoning_tokens,
                requests, failures
         FROM usage_daily WHERE day = ?1 ORDER BY model_id, device_id",
    )?;
    let rows = stmt
        .query_map([day], |row| {
            let project: Option<String> = row.get(3)?;
            Ok(UsageDailyRow {
                day: row.get(0)?,
                device_id: row.get(1)?,
                model_id: row.get(2)?,
                project_id: match project {
                    Some(ref value) if value.is_empty() => None,
                    other => other,
                },
                prompt_tokens: row.get::<_, i64>(4)?.max(0) as u64,
                cached_prompt_tokens: row.get::<_, i64>(5)?.max(0) as u64,
                generated_tokens: row.get::<_, i64>(6)?.max(0) as u64,
                reasoning_tokens: row.get::<_, i64>(7)?.max(0) as u64,
                requests: row.get::<_, i64>(8)?.max(0) as u64,
                failures: row.get::<_, i64>(9)?.max(0) as u64,
            })
        })?
        .collect::<Result<Vec<_>, _>>()?;
    Ok(rows)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn conn_with_usage() -> Connection {
        let conn = Connection::open_in_memory().unwrap();
        conn.execute_batch(
            "CREATE TABLE usage_daily (
               day TEXT NOT NULL,
               device_id TEXT NOT NULL,
               model_id TEXT NOT NULL,
               project_id TEXT,
               prompt_tokens INTEGER NOT NULL DEFAULT 0,
               cached_prompt_tokens INTEGER NOT NULL DEFAULT 0,
               generated_tokens INTEGER NOT NULL DEFAULT 0,
               reasoning_tokens INTEGER NOT NULL DEFAULT 0,
               requests INTEGER NOT NULL DEFAULT 0,
               failures INTEGER NOT NULL DEFAULT 0,
               cumulative_ttft_ms INTEGER NOT NULL DEFAULT 0,
               cumulative_generation_ms INTEGER NOT NULL DEFAULT 0,
               PRIMARY KEY (day, device_id, model_id, project_id)
             );",
        )
        .unwrap();
        conn
    }

    #[test]
    fn records_fold_into_one_daily_row() {
        let conn = conn_with_usage();
        let record = UsageRecord::request(
            "device-1",
            "llama-8b",
            1200,
            340,
            Duration::from_millis(80),
            Duration::from_secs(4),
        );
        record_daily(&conn, "2026-08-26", &record).unwrap();
        record_daily(&conn, "2026-08-26", &record).unwrap();

        let summary = daily_summary(&conn, "2026-08-26").unwrap();
        assert_eq!(summary.len(), 1);
        assert_eq!(summary[0].requests, 2);
        assert_eq!(summary[0].prompt_tokens, 2400);
        assert_eq!(summary[0].generated_tokens, 680);
    }

    #[test]
    fn devices_models_and_days_stay_separate() {
        let conn = conn_with_usage();
        for device in ["device-1", "device-2"] {
            let record = UsageRecord::request(
                device,
                "llama-8b",
                10,
                5,
                Duration::default(),
                Duration::default(),
            );
            record_daily(&conn, "2026-08-26", &record).unwrap();
        }
        let record = UsageRecord::request(
            "device-1",
            "qwen-72b",
            10,
            5,
            Duration::default(),
            Duration::default(),
        );
        record_daily(&conn, "2026-08-25", &record).unwrap();

        assert_eq!(daily_summary(&conn, "2026-08-26").unwrap().len(), 2);
        assert_eq!(daily_summary(&conn, "2026-08-25").unwrap().len(), 1);
    }

    #[test]
    fn failures_are_counted_separately_from_requests() {
        let conn = conn_with_usage();
        let record = UsageRecord {
            failures: 1,
            requests: 0,
            ..UsageRecord::request(
                "device-1",
                "llama-8b",
                50,
                0,
                Duration::default(),
                Duration::default(),
            )
        };
        record_daily(&conn, "2026-08-26", &record).unwrap();
        let summary = daily_summary(&conn, "2026-08-26").unwrap();
        assert_eq!(summary[0].requests, 0);
        assert_eq!(summary[0].failures, 1);
    }
}
