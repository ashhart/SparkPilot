use super::{Connection, StoreError, now};

// Persist project ownership and membership records.

#[derive(Debug, Clone)]
pub struct ProjectRow {
    pub id: uuid::Uuid,
    pub name: String,
    pub owner_device_id: uuid::Uuid,
    pub root_path: String,
    pub state: String,
    pub repository_url: Option<String>,
    pub default_branch: Option<String>,
    pub created_at: String,
    pub updated_at: String,
}

pub fn insert_project(
    conn: &Connection,
    id: &uuid::Uuid,
    name: &str,
    owner_device_id: &uuid::Uuid,
    root_path: &str,
    repository_url: Option<&str>,
) -> Result<(), StoreError> {
    conn.execute(
        "INSERT INTO projects
            (id, name, owner_device_id, root_path, state, repository_url, created_at, updated_at)
         VALUES (?1, ?2, ?3, ?4, 'creating', ?5, ?6, ?6)",
        rusqlite::params![
            id.to_string(),
            name,
            owner_device_id.to_string(),
            root_path,
            repository_url,
            now()
        ],
    )?;
    Ok(())
}

pub fn project_row(conn: &Connection, id: &uuid::Uuid) -> Result<Option<ProjectRow>, StoreError> {
    use rusqlite::OptionalExtension;
    conn.query_row(
        "SELECT id, name, owner_device_id, root_path, state, repository_url, default_branch,
                created_at, updated_at
           FROM projects WHERE id = ?1",
        rusqlite::params![id.to_string()],
        |row| {
            Ok(ProjectRow {
                id: uuid::Uuid::parse_str(&row.get::<_, String>(0)?).map_err(|e| {
                    rusqlite::Error::FromSqlConversionFailure(
                        0,
                        rusqlite::types::Type::Text,
                        Box::new(e),
                    )
                })?,
                name: row.get(1)?,
                owner_device_id: uuid::Uuid::parse_str(&row.get::<_, String>(2)?).map_err(|e| {
                    rusqlite::Error::FromSqlConversionFailure(
                        2,
                        rusqlite::types::Type::Text,
                        Box::new(e),
                    )
                })?,
                root_path: row.get(3)?,
                state: row.get(4)?,
                repository_url: row.get(5)?,
                default_branch: row.get(6)?,
                created_at: row.get(7)?,
                updated_at: row.get(8)?,
            })
        },
    )
    .optional()
    .map_err(StoreError::from)
}

pub fn project_rows(conn: &Connection, limit: usize) -> Result<Vec<ProjectRow>, StoreError> {
    let mut stmt = conn.prepare(
        "SELECT id, name, owner_device_id, root_path, state, repository_url, default_branch,
                created_at, updated_at
           FROM projects ORDER BY created_at DESC LIMIT ?1",
    )?;
    let rows = stmt
        .query_map([limit.min(200) as i64], |row| {
            Ok(ProjectRow {
                id: uuid::Uuid::parse_str(&row.get::<_, String>(0)?).map_err(|e| {
                    rusqlite::Error::FromSqlConversionFailure(
                        0,
                        rusqlite::types::Type::Text,
                        Box::new(e),
                    )
                })?,
                name: row.get(1)?,
                owner_device_id: uuid::Uuid::parse_str(&row.get::<_, String>(2)?).map_err(|e| {
                    rusqlite::Error::FromSqlConversionFailure(
                        2,
                        rusqlite::types::Type::Text,
                        Box::new(e),
                    )
                })?,
                root_path: row.get(3)?,
                state: row.get(4)?,
                repository_url: row.get(5)?,
                default_branch: row.get(6)?,
                created_at: row.get(7)?,
                updated_at: row.get(8)?,
            })
        })?
        .collect::<Result<Vec<_>, _>>()?;
    Ok(rows)
}

pub fn update_project_state(
    conn: &Connection,
    id: &uuid::Uuid,
    state: &str,
) -> Result<(), StoreError> {
    conn.execute(
        "UPDATE projects SET state = ?2, updated_at = ?3 WHERE id = ?1",
        rusqlite::params![id.to_string(), state, now()],
    )?;
    Ok(())
}

pub fn remove_project_row(conn: &Connection, id: &uuid::Uuid) -> Result<(), StoreError> {
    conn.execute(
        "DELETE FROM projects WHERE id = ?1",
        rusqlite::params![id.to_string()],
    )?;
    Ok(())
}

pub fn insert_project_member(
    conn: &Connection,
    project_id: &uuid::Uuid,
    device_id: &uuid::Uuid,
    permission: &str,
) -> Result<(), StoreError> {
    conn.execute(
        "INSERT OR IGNORE INTO project_members (project_id, device_id, permission, granted_at)
         VALUES (?1, ?2, ?3, ?4)",
        rusqlite::params![
            project_id.to_string(),
            device_id.to_string(),
            permission,
            now()
        ],
    )?;
    Ok(())
}

/// Highest project permission for a device (`None` when not a member).
pub fn project_permission(
    conn: &Connection,
    project_id: &uuid::Uuid,
    device_id: &uuid::Uuid,
) -> Result<Option<String>, StoreError> {
    use rusqlite::OptionalExtension;
    conn.query_row(
        "SELECT permission FROM project_members
          WHERE project_id = ?1 AND device_id = ?2",
        rusqlite::params![project_id.to_string(), device_id.to_string()],
        |row| row.get(0),
    )
    .optional()
    .map_err(StoreError::from)
}
