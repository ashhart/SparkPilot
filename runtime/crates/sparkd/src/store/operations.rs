use super::{Connection, OptionalExtension, StoreError, Uuid, params};

// Persist operation records for the REST surface.

#[derive(Debug, Clone, serde::Serialize)]
pub struct OperationRow {
    pub id: Uuid,
    pub kind: String,
    pub state: String,
    pub actor_device_id: Uuid,
    pub resource_id: Option<String>,
    pub progress: Option<f64>,
    pub stage: Option<String>,
    pub created_at: String,
    pub updated_at: String,
    pub started_at: Option<String>,
    pub completed_at: Option<String>,
    pub error_code: Option<String>,
    pub result: Option<serde_json::Value>,
    pub cancellable: bool,
}

pub fn operation_row(conn: &Connection, id: Uuid) -> Result<Option<OperationRow>, StoreError> {
    conn.query_row(
        "SELECT id, kind, state, actor_device_id, resource_id, progress, stage,
                created_at, updated_at, started_at, completed_at, error_code,
                result_json, cancellable, input_json
           FROM operations WHERE id = ?1",
        params![id.to_string()],
        row_from_operation,
    )
    .optional()
    .map_err(Into::into)
}

/// Remove expired replay state in bounded batches without touching audit rows.
pub fn prune_expired_records(conn: &Connection, at: &str) -> Result<usize, StoreError> {
    let mut removed = 0;
    for table in ["idempotency_records", "pairing_challenges"] {
        removed += conn.execute(&format!(
            "DELETE FROM {table} WHERE rowid IN (SELECT rowid FROM {table} WHERE expires_at <= ?1 AND julianday(expires_at) <= julianday(?1) ORDER BY expires_at LIMIT 1000)"
        ), [at])?;
    }
    Ok(removed)
}

/// §34.4: forget aggregated usage after its retention window; 0 days keeps it indefinitely.
pub fn prune_usage_daily(
    conn: &Connection,
    now_rfc3339: &str,
    retention_days: u64,
) -> Result<usize, StoreError> {
    if retention_days == 0 {
        return Ok(0);
    }
    let now =
        time::OffsetDateTime::parse(now_rfc3339, &time::format_description::well_known::Rfc3339)
            .map_err(|error| StoreError::Sqlite(format!("retention clock unreadable: {error}")))?;
    let Some(cutoff) = i64::try_from(retention_days)
        .ok()
        .and_then(|days| days.checked_mul(86_400))
        .and_then(|seconds| now.checked_sub(time::Duration::seconds(seconds)))
    else {
        return Ok(0);
    };
    // `usage_daily.day` is the ISO date, which is the first ten characters of the timestamp.
    let cutoff = crate::clock::format_utc(cutoff)[..10].to_owned();
    Ok(conn.execute("DELETE FROM usage_daily WHERE day < ?1", [cutoff])?)
}

/// §60.3: keep the replay floor, then each class's own window; older cursors receive EVENT_CURSOR_EXPIRED.
pub fn prune_events(
    conn: &Connection,
    retention: &crate::events::EventRetention,
    now_rfc3339: &str,
) -> Result<usize, StoreError> {
    let now =
        time::OffsetDateTime::parse(now_rfc3339, &time::format_description::well_known::Rfc3339)
            .map_err(|error| StoreError::Sqlite(format!("retention clock unreadable: {error}")))?;
    let cutoff = |value: i64, seconds_per_unit: i64| {
        value
            .checked_mul(seconds_per_unit)
            .filter(|seconds| *seconds >= 0)
            .and_then(|seconds| now.checked_sub(time::Duration::seconds(seconds)))
            .map(crate::clock::format_utc)
            .unwrap_or_else(|| "0000-01-01T00:00:00Z".into())
    };
    let removed = conn.execute(
        "DELETE FROM events
          WHERE sequence NOT IN (SELECT sequence FROM events ORDER BY sequence DESC LIMIT ?1)
            AND occurred_at < ?2
            AND occurred_at < (CASE
                  WHEN event_type LIKE 'security.%'
                    OR event_type LIKE 'device.%'
                    OR event_type LIKE 'pairing.%' THEN ?3
                  WHEN event_type LIKE 'operation.%' THEN ?4
                  ELSE ?5 END)",
        rusqlite::params![
            retention.replay_minimum_rows as i64,
            cutoff(retention.replay_minimum_hours, 3_600),
            cutoff(retention.security_days, 86_400),
            cutoff(retention.operation_days, 86_400),
            cutoff(retention.lifecycle_days, 86_400),
        ],
    )?;
    Ok(removed)
}

/// §45.2 step 4: find live work of the given kinds so an update cannot interrupt a filesystem mutation.
pub fn live_operation_of_kind(
    conn: &Connection,
    kinds: &[&str],
) -> Result<Option<(String, String)>, StoreError> {
    let placeholders = kinds
        .iter()
        .enumerate()
        .map(|(index, _)| format!("?{}", index + 1))
        .collect::<Vec<_>>()
        .join(",");
    let sql = format!(
        "SELECT id, kind FROM operations INDEXED BY operations_state_idx
          WHERE state IN ('requested','validating','queued','running','cancelling')
            AND kind IN ({placeholders})
          ORDER BY created_at LIMIT 1"
    );
    let params: Vec<&dyn rusqlite::ToSql> = kinds
        .iter()
        .map(|kind| kind as &dyn rusqlite::ToSql)
        .collect();
    conn.query_row(&sql, params.as_slice(), |row| {
        Ok((row.get(0)?, row.get(1)?))
    })
    .optional()
    .map_err(Into::into)
}

/// Page newest operations by created_at/id, restricting to viewer-owned rows unless an authorized owner/admin requests all.
pub fn operation_rows_page(
    conn: &Connection,
    viewer: Option<Uuid>,
    after: Option<(&str, &str)>,
    limit: usize,
) -> Result<(Vec<OperationRow>, bool), StoreError> {
    let limit = limit.clamp(1, 200);
    let mut where_parts: Vec<String> = Vec::new();
    let mut params: Vec<rusqlite::types::Value> = Vec::new();
    if let Some(device) = viewer {
        params.push(rusqlite::types::Value::Text(device.to_string()));
        where_parts.push(format!("actor_device_id = ?{}", params.len()));
    }
    if let Some((created_at, id)) = after {
        params.push(rusqlite::types::Value::Text(created_at.to_owned()));
        let ca = params.len();
        params.push(rusqlite::types::Value::Text(id.to_owned()));
        let idp = params.len();
        where_parts.push(format!(
            "(created_at < ?{ca} OR (created_at = ?{ca} AND id < ?{idp}))"
        ));
    }
    params.push(rusqlite::types::Value::Integer(limit as i64 + 1));
    let limit_idx = params.len();
    let mut sql = String::from(
        "SELECT id, kind, state, actor_device_id, resource_id, progress, stage,
                created_at, updated_at, started_at, completed_at, error_code,
                result_json, cancellable, input_json FROM operations",
    );
    if !where_parts.is_empty() {
        sql.push_str(" WHERE ");
        sql.push_str(&where_parts.join(" AND "));
    }
    sql.push_str(&format!(
        " ORDER BY created_at DESC, id DESC LIMIT ?{limit_idx}"
    ));
    let mut stmt = conn.prepare(&sql)?;
    let mut rows = stmt
        .query_map(
            rusqlite::params_from_iter(params.iter()),
            row_from_operation,
        )?
        .collect::<Result<Vec<_>, _>>()?;
    let has_more = rows.len() > limit;
    if has_more {
        rows.truncate(limit);
    }
    Ok((rows, has_more))
}

pub fn operation_rows(conn: &Connection) -> Result<Vec<OperationRow>, StoreError> {
    let mut stmt = conn.prepare(
        "SELECT id, kind, state, actor_device_id, resource_id, progress, stage,
                created_at, updated_at, started_at, completed_at, error_code,
                result_json, cancellable, input_json
           FROM operations ORDER BY created_at DESC LIMIT 200",
    )?;
    let rows = stmt
        .query_map([], row_from_operation)?
        .collect::<Result<Vec<_>, _>>()?;
    Ok(rows)
}

fn row_from_operation(r: &rusqlite::Row<'_>) -> rusqlite::Result<OperationRow> {
    let result_json: Option<String> = r.get(12)?;
    let mut result: Option<serde_json::Value> = result_json
        .map(|value| {
            serde_json::from_str(&value).map_err(|error| {
                rusqlite::Error::FromSqlConversionFailure(
                    12,
                    rusqlite::types::Type::Text,
                    Box::new(error),
                )
            })
        })
        .transpose()?;
    if r.get::<_, String>(1)? == "automation.run" {
        let input: Option<String> = r.get(14)?;
        let notify = input
            .and_then(|raw| serde_json::from_str::<serde_json::Value>(&raw).ok())
            .and_then(|input| input.get("notify").and_then(serde_json::Value::as_bool))
            .unwrap_or(false);
        let result = result.get_or_insert_with(|| serde_json::json!({}));
        if let Some(object) = result.as_object_mut() {
            object.insert("notify".into(), notify.into());
        }
    }
    Ok(OperationRow {
        id: Uuid::parse_str(&r.get::<_, String>(0)?).map_err(|e| {
            rusqlite::Error::FromSqlConversionFailure(0, rusqlite::types::Type::Text, Box::new(e))
        })?,
        kind: r.get(1)?,
        state: r.get(2)?,
        actor_device_id: Uuid::parse_str(&r.get::<_, String>(3)?).map_err(|e| {
            rusqlite::Error::FromSqlConversionFailure(3, rusqlite::types::Type::Text, Box::new(e))
        })?,
        resource_id: r.get(4)?,
        progress: r.get(5)?,
        stage: r.get(6)?,
        created_at: r.get(7)?,
        updated_at: r.get(8)?,
        started_at: r.get(9)?,
        completed_at: r.get(10)?,
        error_code: r.get(11)?,
        result,
        cancellable: r.get(13)?,
    })
}
