use super::builds::map_build;
use super::{BuildRow, Connection, StoreError, delete_build_artifacts};

/// Record the digest of a claim proof and its deadline (§43.5).
pub fn set_build_claim(
    conn: &Connection,
    build_id: &uuid::Uuid,
    token_hash: &[u8],
    expires_at: &str,
) -> Result<(), StoreError> {
    conn.execute(
        "UPDATE builds SET claim_token_hash = ?2, claim_expires_at = ?3 WHERE id = ?1",
        rusqlite::params![build_id.to_string(), token_hash, expires_at],
    )?;
    Ok(())
}

/// Clear claim proof after recording results so leaked tokens cannot authorize finished-job replays.
pub fn clear_build_claim(conn: &Connection, build_id: &uuid::Uuid) -> Result<(), StoreError> {
    conn.execute(
        "UPDATE builds SET claim_token_hash = NULL, claim_expires_at = NULL WHERE id = ?1",
        rusqlite::params![build_id.to_string()],
    )?;
    Ok(())
}

#[allow(clippy::too_many_arguments)]
pub fn claim_build(
    conn: &Connection,
    build_id: &uuid::Uuid,
    worker_id: &uuid::Uuid,
    claim_token_hash: &[u8],
    artifact_token_hash: &[u8],
    claim_request_id: &uuid::Uuid,
    expires_at: &str,
    recipe_json: &str,
    recipe_sha256: &str,
    timestamp: &str,
) -> Result<bool, StoreError> {
    let changed = conn.execute(
        "UPDATE builds
            SET status = 'claimed', worker_id = ?2, claim_token_hash = ?3,
                artifact_token_hash = ?4, claim_request_id = ?5, claim_expires_at = ?6,
                recipe_json = ?7, recipe_sha256 = ?8,
                claim_generation = claim_generation + 1, updated_at = ?9
          WHERE id = ?1 AND status = 'queued' AND worker_id IS NULL",
        rusqlite::params![
            build_id.to_string(),
            worker_id.to_string(),
            claim_token_hash,
            artifact_token_hash,
            claim_request_id.to_string(),
            expires_at,
            recipe_json,
            recipe_sha256,
            timestamp,
        ],
    )?;
    Ok(changed == 1)
}

#[allow(clippy::too_many_arguments)]
pub fn renew_build_claim(
    conn: &Connection,
    build_id: &uuid::Uuid,
    worker_id: &uuid::Uuid,
    claim_token_hash: &[u8],
    claim_generation: i64,
    now: &str,
    expires_at: &str,
    timestamp: &str,
) -> Result<bool, StoreError> {
    let changed = conn.execute(
        "UPDATE builds SET status = 'running', claim_expires_at = ?6, updated_at = ?7
          WHERE id = ?1 AND worker_id = ?2 AND claim_token_hash = ?3
            AND claim_generation = ?4 AND claim_expires_at > ?5
            AND status IN ('claimed','running')",
        rusqlite::params![
            build_id.to_string(),
            worker_id.to_string(),
            claim_token_hash,
            claim_generation,
            now,
            expires_at,
            timestamp
        ],
    )?;
    Ok(changed == 1)
}

#[allow(clippy::too_many_arguments)]
pub fn finish_build_claim(
    conn: &Connection,
    build_id: &uuid::Uuid,
    worker_id: &uuid::Uuid,
    claim_token_hash: &[u8],
    claim_generation: i64,
    recipe_sha256: &str,
    status: &str,
    result_json: &str,
    timestamp: &str,
) -> Result<bool, StoreError> {
    let changed = conn.execute(
        "UPDATE builds
            SET status = ?6, result_json = ?7, updated_at = ?8,
                claim_token_hash = NULL, claim_expires_at = NULL,
                artifact_token_hash = NULL
          WHERE id = ?1 AND worker_id = ?2 AND claim_token_hash = ?3
            AND claim_generation = ?4 AND recipe_sha256 = ?5
            AND status IN ('claimed','running') AND claim_expires_at > ?8",
        rusqlite::params![
            build_id.to_string(),
            worker_id.to_string(),
            claim_token_hash,
            claim_generation,
            recipe_sha256,
            status,
            result_json,
            timestamp,
        ],
    )?;
    Ok(changed == 1)
}

pub fn expired_build_claims(
    conn: &Connection,
    timestamp: &str,
) -> Result<Vec<BuildRow>, StoreError> {
    let mut statement = conn.prepare(
        "SELECT id, project_id, operation_id, worker_id, commit_sha, source_sha256, scheme,
                configuration, destination, actions_json, timeout_seconds, status, result_json,
                requested_by_device_id, created_at, updated_at, claim_token_hash,
                claim_expires_at, claim_generation, claim_request_id, requirements_json,
                recipe_json, recipe_sha256, artifact_token_hash
           FROM builds
          WHERE status IN ('claimed','running') AND claim_expires_at <= ?1
          ORDER BY created_at",
    )?;
    statement
        .query_map([timestamp], map_build)?
        .collect::<Result<Vec<_>, _>>()
        .map_err(StoreError::from)
}

pub fn requeue_expired_build(
    conn: &Connection,
    build_id: &uuid::Uuid,
    claim_generation: i64,
    timestamp: &str,
) -> Result<bool, StoreError> {
    let changed = conn.execute(
        "UPDATE builds SET status = 'queued', worker_id = NULL,
                claim_token_hash = NULL, claim_expires_at = NULL,
                artifact_token_hash = NULL, claim_request_id = NULL,
                recipe_json = NULL, recipe_sha256 = NULL,
                updated_at = ?3
          WHERE id = ?1 AND claim_generation = ?2
            AND status IN ('claimed','running') AND claim_expires_at <= ?3",
        rusqlite::params![build_id.to_string(), claim_generation, timestamp],
    )?;
    if changed == 1 {
        delete_build_artifacts(conn, build_id, claim_generation)?;
    }
    Ok(changed == 1)
}

pub fn cancel_expired_build(
    conn: &Connection,
    build_id: &uuid::Uuid,
    claim_generation: i64,
    timestamp: &str,
) -> Result<bool, StoreError> {
    let changed = conn.execute(
        "UPDATE builds SET status = 'cancelled', claim_token_hash = NULL,
                claim_expires_at = NULL, artifact_token_hash = NULL, updated_at = ?3
          WHERE id = ?1 AND claim_generation = ?2
            AND status IN ('claimed','running') AND claim_expires_at <= ?3",
        rusqlite::params![build_id.to_string(), claim_generation, timestamp],
    )?;
    if changed == 1 {
        delete_build_artifacts(conn, build_id, claim_generation)?;
    }
    Ok(changed == 1)
}
