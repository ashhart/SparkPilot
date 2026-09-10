use super::{Connection, StoreError, now, parse_uuid};

// Persist registered build workers and build jobs.

#[derive(Debug, Clone)]
pub struct BuildWorkerRow {
    pub id: uuid::Uuid,
    pub display_name: String,
    pub device_id: uuid::Uuid,
    pub platform_version: String,
    pub xcode_version: String,
    pub capabilities_json: String,
    pub state: String,
    pub registered_at: String,
    pub last_seen_at: Option<String>,
    pub heartbeat_expires_at: Option<String>,
}

pub fn insert_build_worker(conn: &Connection, row: &BuildWorkerRow) -> Result<(), StoreError> {
    insert_build_worker_at(conn, row, &now())
}

pub fn insert_build_worker_at(
    conn: &Connection,
    row: &BuildWorkerRow,
    timestamp: &str,
) -> Result<(), StoreError> {
    conn.execute(
        "INSERT INTO build_workers
            (id, display_name, device_id, platform_version, xcode_version, capabilities_json,
             state, registered_at, last_seen_at, heartbeat_expires_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)",
        rusqlite::params![
            row.id.to_string(),
            row.display_name,
            row.device_id.to_string(),
            row.platform_version,
            row.xcode_version,
            row.capabilities_json,
            row.state,
            timestamp,
            row.last_seen_at,
            row.heartbeat_expires_at,
        ],
    )?;
    Ok(())
}

pub fn refresh_build_worker_registration(
    conn: &Connection,
    row: &BuildWorkerRow,
    timestamp: &str,
) -> Result<(), StoreError> {
    let changed = conn.execute(
        "UPDATE build_workers
            SET display_name = ?3, platform_version = ?4, xcode_version = ?5,
                capabilities_json = ?6,
                state = CASE WHEN state = 'revoked' THEN state ELSE ?7 END,
                last_seen_at = ?8,
                heartbeat_expires_at = CASE WHEN state = 'revoked' THEN heartbeat_expires_at ELSE ?9 END
          WHERE id = ?1 AND device_id = ?2",
        rusqlite::params![
            row.id.to_string(),
            row.device_id.to_string(),
            row.display_name,
            row.platform_version,
            row.xcode_version,
            row.capabilities_json,
            row.state,
            timestamp,
            row.heartbeat_expires_at,
        ],
    )?;
    if changed == 1 {
        Ok(())
    } else {
        Err(StoreError::NotFound("build worker"))
    }
}

pub fn build_worker_rows(conn: &Connection) -> Result<Vec<BuildWorkerRow>, StoreError> {
    let mut stmt = conn.prepare(
        "SELECT id, display_name, device_id, platform_version, xcode_version, capabilities_json, state, registered_at, last_seen_at, heartbeat_expires_at
           FROM build_workers WHERE state != 'revoked' ORDER BY display_name",
    )?;
    let rows = stmt
        .query_map([], |row| {
            Ok(BuildWorkerRow {
                id: parse_uuid(&row.get::<_, String>(0)?, 0)?,
                display_name: row.get(1)?,
                device_id: parse_uuid(&row.get::<_, String>(2)?, 2)?,
                platform_version: row.get(3)?,
                xcode_version: row.get(4)?,
                capabilities_json: row.get(5)?,
                state: row.get(6)?,
                registered_at: row.get(7)?,
                last_seen_at: row.get(8)?,
                heartbeat_expires_at: row.get(9)?,
            })
        })?
        .collect::<Result<Vec<_>, _>>()?;
    Ok(rows)
}

pub fn build_worker_row(
    conn: &Connection,
    id: &uuid::Uuid,
) -> Result<Option<BuildWorkerRow>, StoreError> {
    use rusqlite::OptionalExtension;
    conn.query_row(
        "SELECT id, display_name, device_id, platform_version, xcode_version, capabilities_json, state, registered_at, last_seen_at, heartbeat_expires_at
           FROM build_workers WHERE id = ?1",
        rusqlite::params![id.to_string()],
        |row| {
            Ok(BuildWorkerRow {
                id: parse_uuid(&row.get::<_, String>(0)?, 0)?,
                display_name: row.get(1)?,
                device_id: parse_uuid(&row.get::<_, String>(2)?, 2)?,
                platform_version: row.get(3)?,
                xcode_version: row.get(4)?,
                capabilities_json: row.get(5)?,
                state: row.get(6)?,
                registered_at: row.get(7)?,
                last_seen_at: row.get(8)?,
                heartbeat_expires_at: row.get(9)?,
            })
        },
    )
    .optional()
    .map_err(StoreError::from)
}

pub fn update_build_worker_state(
    conn: &Connection,
    id: &uuid::Uuid,
    state: &str,
) -> Result<(), StoreError> {
    update_build_worker_state_at(conn, id, state, &now())
}

pub fn update_build_worker_state_at(
    conn: &Connection,
    id: &uuid::Uuid,
    state: &str,
    timestamp: &str,
) -> Result<(), StoreError> {
    conn.execute(
        "UPDATE build_workers SET state = ?2, last_seen_at = ?3 WHERE id = ?1",
        rusqlite::params![id.to_string(), state, timestamp],
    )?;
    Ok(())
}

pub fn heartbeat_build_worker(
    conn: &Connection,
    id: &uuid::Uuid,
    timestamp: &str,
    heartbeat_expires_at: &str,
) -> Result<(), StoreError> {
    let changed = conn.execute(
        "UPDATE build_workers
            SET state = CASE WHEN state = 'busy' THEN 'busy' ELSE 'online' END,
                last_seen_at = ?2, heartbeat_expires_at = ?3
          WHERE id = ?1 AND state != 'revoked'",
        rusqlite::params![id.to_string(), timestamp, heartbeat_expires_at],
    )?;
    if changed == 1 {
        Ok(())
    } else {
        Err(StoreError::NotFound("build_worker"))
    }
}

pub fn active_build_count_for_worker(
    conn: &Connection,
    worker_id: &uuid::Uuid,
) -> Result<usize, StoreError> {
    let count: i64 = conn.query_row(
        "SELECT COUNT(*) FROM builds
          WHERE worker_id = ?1 AND status IN ('claimed','running')",
        [worker_id.to_string()],
        |row| row.get(0),
    )?;
    Ok(count.max(0) as usize)
}
