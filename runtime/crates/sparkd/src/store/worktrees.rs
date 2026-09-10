use super::{Connection, StoreError, now};

#[derive(Debug, Clone)]
pub struct WorktreeRow {
    pub id: uuid::Uuid,
    pub project_id: uuid::Uuid,
    pub operation_id: Option<uuid::Uuid>,
    pub path: String,
    pub base_commit: String,
    pub branch_name: String,
    pub state: String,
    pub created_at: String,
}

pub fn insert_worktree(
    conn: &Connection,
    id: &uuid::Uuid,
    project_id: &uuid::Uuid,
    operation_id: Option<&uuid::Uuid>,
    path: &str,
    base_commit: &str,
    branch_name: &str,
) -> Result<(), StoreError> {
    conn.execute(
        "INSERT INTO project_worktrees
            (id, project_id, operation_id, path, base_commit, branch_name, state, created_at, updated_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, 'creating', ?7, ?7)",
        rusqlite::params![
            id.to_string(),
            project_id.to_string(),
            operation_id.map(|o| o.to_string()),
            path,
            base_commit,
            branch_name,
            now()
        ],
    )?;
    Ok(())
}

pub fn worktree_row(conn: &Connection, id: &uuid::Uuid) -> Result<Option<WorktreeRow>, StoreError> {
    use rusqlite::OptionalExtension;
    conn.query_row(
        "SELECT id, project_id, operation_id, path, base_commit, branch_name, state, created_at
           FROM project_worktrees WHERE id = ?1",
        rusqlite::params![id.to_string()],
        |row| {
            Ok(WorktreeRow {
                id: uuid::Uuid::parse_str(&row.get::<_, String>(0)?).map_err(|e| {
                    rusqlite::Error::FromSqlConversionFailure(
                        0,
                        rusqlite::types::Type::Text,
                        Box::new(e),
                    )
                })?,
                project_id: uuid::Uuid::parse_str(&row.get::<_, String>(1)?).map_err(|e| {
                    rusqlite::Error::FromSqlConversionFailure(
                        1,
                        rusqlite::types::Type::Text,
                        Box::new(e),
                    )
                })?,
                operation_id: row
                    .get::<_, Option<String>>(2)?
                    .map(|s| uuid::Uuid::parse_str(&s))
                    .transpose()
                    .map_err(|e| {
                        rusqlite::Error::FromSqlConversionFailure(
                            2,
                            rusqlite::types::Type::Text,
                            Box::new(e),
                        )
                    })?,
                path: row.get(3)?,
                base_commit: row.get(4)?,
                branch_name: row.get(5)?,
                state: row.get(6)?,
                created_at: row.get(7)?,
            })
        },
    )
    .optional()
    .map_err(StoreError::from)
}

pub fn update_worktree_state(
    conn: &Connection,
    id: &uuid::Uuid,
    state: &str,
) -> Result<(), StoreError> {
    conn.execute(
        "UPDATE project_worktrees SET state = ?2, updated_at = ?3 WHERE id = ?1",
        rusqlite::params![id.to_string(), state, now()],
    )?;
    Ok(())
}
