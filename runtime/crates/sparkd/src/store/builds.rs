use super::{Connection, StoreError, now, parse_uuid};

#[derive(Debug, Clone, serde::Serialize)]
pub struct BuildRow {
    pub id: uuid::Uuid,
    pub project_id: uuid::Uuid,
    pub operation_id: uuid::Uuid,
    pub requested_by_device_id: uuid::Uuid,
    pub worker_id: Option<uuid::Uuid>,
    pub commit_sha: String,
    pub source_sha256: String,
    pub scheme: String,
    pub configuration: String,
    pub destination: String,
    pub actions_json: String,
    pub timeout_seconds: i64,
    pub status: String,
    pub result_json: String,
    pub created_at: String,
    pub updated_at: String,
    /// Store the claimed worker proof's SHA-256 hex bytes, absent before claim.
    pub claim_token_hash: Option<Vec<u8>>,
    pub claim_expires_at: Option<String>,
    pub claim_generation: i64,
    pub claim_request_id: Option<uuid::Uuid>,
    pub requirements_json: String,
    pub recipe_json: Option<String>,
    pub recipe_sha256: Option<String>,
    pub artifact_token_hash: Option<Vec<u8>>,
}

pub fn insert_build(conn: &Connection, row: &BuildRow) -> Result<(), StoreError> {
    insert_build_at(conn, row, &now())
}

pub fn insert_build_at(
    conn: &Connection,
    row: &BuildRow,
    timestamp: &str,
) -> Result<(), StoreError> {
    conn.execute(
        "INSERT INTO builds
            (id, project_id, operation_id, worker_id, commit_sha, source_sha256, scheme, configuration,
             destination, actions_json, timeout_seconds, status, result_json,
             requested_by_device_id, created_at, updated_at, requirements_json)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, 'queued', '{}', ?12, ?13, ?13, ?14)",
        rusqlite::params![
            row.id.to_string(),
            row.project_id.to_string(),
            row.operation_id.to_string(),
            row.worker_id.map(|w| w.to_string()),
            row.commit_sha,
            row.source_sha256,
            row.scheme,
            row.configuration,
            row.destination,
            row.actions_json,
            row.timeout_seconds,
            row.requested_by_device_id.to_string(),
            timestamp,
            row.requirements_json,
        ],
    )?;
    Ok(())
}

pub fn build_row(conn: &Connection, id: &uuid::Uuid) -> Result<Option<BuildRow>, StoreError> {
    use rusqlite::OptionalExtension;
    conn.query_row(
        "SELECT id, project_id, operation_id, worker_id, commit_sha, source_sha256, scheme, configuration, destination,
                actions_json, timeout_seconds, status, result_json, requested_by_device_id,
                created_at, updated_at, claim_token_hash, claim_expires_at, claim_generation,
                claim_request_id, requirements_json, recipe_json, recipe_sha256, artifact_token_hash
           FROM builds WHERE id = ?1",
        rusqlite::params![id.to_string()],
        map_build,
    )
    .optional()
    .map_err(StoreError::from)
}

pub fn build_claim_for_request(
    conn: &Connection,
    worker_id: &uuid::Uuid,
    request_id: &uuid::Uuid,
    timestamp: &str,
) -> Result<Option<BuildRow>, StoreError> {
    use rusqlite::OptionalExtension;
    conn.query_row(
        "SELECT id, project_id, operation_id, worker_id, commit_sha, source_sha256, scheme, configuration, destination,
                actions_json, timeout_seconds, status, result_json, requested_by_device_id,
                created_at, updated_at, claim_token_hash, claim_expires_at, claim_generation,
                claim_request_id, requirements_json, recipe_json, recipe_sha256, artifact_token_hash
           FROM builds
          WHERE worker_id = ?1 AND claim_request_id = ?2
            AND status IN ('claimed','running') AND claim_expires_at > ?3",
        rusqlite::params![worker_id.to_string(), request_id.to_string(), timestamp],
        map_build,
    )
    .optional()
    .map_err(StoreError::from)
}

pub fn build_rows(conn: &Connection, limit: usize) -> Result<Vec<BuildRow>, StoreError> {
    let mut stmt = conn.prepare(
        "SELECT id, project_id, operation_id, worker_id, commit_sha, source_sha256, scheme, configuration, destination,
                actions_json, timeout_seconds, status, result_json, requested_by_device_id,
                created_at, updated_at, claim_token_hash, claim_expires_at, claim_generation,
                claim_request_id, requirements_json, recipe_json, recipe_sha256, artifact_token_hash
           FROM builds ORDER BY created_at DESC LIMIT ?1",
    )?;
    let rows = stmt
        .query_map([limit.min(200) as i64], map_build)?
        .collect::<Result<Vec<_>, _>>()?;
    Ok(rows)
}

pub(super) fn map_build(row: &rusqlite::Row<'_>) -> rusqlite::Result<BuildRow> {
    Ok(BuildRow {
        id: parse_uuid(&row.get::<_, String>(0)?, 0)?,
        project_id: parse_uuid(&row.get::<_, String>(1)?, 1)?,
        operation_id: parse_uuid(&row.get::<_, String>(2)?, 2)?,
        worker_id: row
            .get::<_, Option<String>>(3)?
            .map(|s| parse_uuid(&s, 3))
            .transpose()?,
        commit_sha: row.get(4)?,
        source_sha256: row.get(5)?,
        scheme: row.get(6)?,
        configuration: row.get(7)?,
        destination: row.get(8)?,
        actions_json: row.get(9)?,
        timeout_seconds: row.get(10)?,
        status: row.get(11)?,
        result_json: row.get(12)?,
        requested_by_device_id: parse_uuid(&row.get::<_, String>(13)?, 13)?,
        created_at: row.get(14)?,
        updated_at: row.get(15)?,
        claim_token_hash: row.get(16)?,
        claim_expires_at: row.get(17)?,
        claim_generation: row.get(18)?,
        claim_request_id: row
            .get::<_, Option<String>>(19)?
            .map(|value| parse_uuid(&value, 19))
            .transpose()?,
        requirements_json: row.get(20)?,
        recipe_json: row.get(21)?,
        recipe_sha256: row.get(22)?,
        artifact_token_hash: row.get(23)?,
    })
}

pub fn update_build_status(
    conn: &Connection,
    id: &uuid::Uuid,
    status: &str,
) -> Result<(), StoreError> {
    update_build_status_at(conn, id, status, &now())
}

pub fn update_build_status_at(
    conn: &Connection,
    id: &uuid::Uuid,
    status: &str,
    timestamp: &str,
) -> Result<(), StoreError> {
    conn.execute(
        "UPDATE builds SET status = ?2, updated_at = ?3 WHERE id = ?1",
        rusqlite::params![id.to_string(), status, timestamp],
    )?;
    Ok(())
}

pub fn update_build_worker(
    conn: &Connection,
    id: &uuid::Uuid,
    worker_id: &uuid::Uuid,
) -> Result<(), StoreError> {
    update_build_worker_at(conn, id, worker_id, &now())
}

pub fn update_build_worker_at(
    conn: &Connection,
    id: &uuid::Uuid,
    worker_id: &uuid::Uuid,
    timestamp: &str,
) -> Result<(), StoreError> {
    conn.execute(
        "UPDATE builds SET worker_id = ?2, updated_at = ?3 WHERE id = ?1",
        rusqlite::params![id.to_string(), worker_id.to_string(), timestamp],
    )?;
    Ok(())
}

pub fn update_build_result(
    conn: &Connection,
    id: &uuid::Uuid,
    status: &str,
    result_json: &str,
) -> Result<(), StoreError> {
    update_build_result_at(conn, id, status, result_json, &now())
}

pub fn update_build_result_at(
    conn: &Connection,
    id: &uuid::Uuid,
    status: &str,
    result_json: &str,
    timestamp: &str,
) -> Result<(), StoreError> {
    conn.execute(
        "UPDATE builds SET status = ?2, result_json = ?3, updated_at = ?4 WHERE id = ?1",
        rusqlite::params![id.to_string(), status, result_json, timestamp],
    )?;
    Ok(())
}
