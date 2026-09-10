use super::{Connection, StoreError, params};

/// Check durable pending side effects as well as runtime views before allowing conflicting resource mutations.
pub fn has_non_terminal_operation(
    conn: &Connection,
    kind: &str,
    resource_id: &str,
) -> Result<bool, StoreError> {
    conn.query_row(
        "SELECT EXISTS(
             SELECT 1 FROM operations
              WHERE kind = ?1 AND resource_id = ?2
                AND state IN ('queued', 'running', 'cancelling')
         )",
        params![kind, resource_id],
        |row| row.get(0),
    )
    .map_err(Into::into)
}

/// Persist terminal identity with its exact container binding for authoritative restart handling.
#[allow(clippy::too_many_arguments)]
pub fn insert_terminal(
    conn: &Connection,
    terminal_id: &uuid::Uuid,
    project_id: &uuid::Uuid,
    creator_device_id: &uuid::Uuid,
    container_id: &str,
    shell: &str,
    created_at: &str,
) -> Result<(), StoreError> {
    conn.execute(
        "INSERT INTO project_terminals
            (id, project_id, creator_device_id, container_id, shell, state, created_at)
         VALUES (?1, ?2, ?3, ?4, ?5, 'running', ?6)",
        rusqlite::params![
            terminal_id.to_string(),
            project_id.to_string(),
            creator_device_id.to_string(),
            container_id,
            shell,
            created_at
        ],
    )?;
    Ok(())
}

/// Close by project plus terminal id so one project cannot address another's session.
pub fn close_terminal(
    conn: &Connection,
    project_id: &uuid::Uuid,
    terminal_id: &uuid::Uuid,
    closed_at: &str,
) -> Result<bool, StoreError> {
    let changed = conn.execute(
        "UPDATE project_terminals
            SET state = 'closed', closed_at = ?3
          WHERE id = ?1 AND project_id = ?2 AND state = 'running'",
        rusqlite::params![terminal_id.to_string(), project_id.to_string(), closed_at],
    )?;
    Ok(changed == 1)
}

/// The stored record for one session, resolved by the compound key.
pub fn terminal_row(
    conn: &Connection,
    project_id: &uuid::Uuid,
    terminal_id: &uuid::Uuid,
) -> Result<Option<(String, String, String)>, StoreError> {
    use rusqlite::OptionalExtension;
    conn.query_row(
        "SELECT container_id, shell, state FROM project_terminals
          WHERE id = ?1 AND project_id = ?2",
        rusqlite::params![terminal_id.to_string(), project_id.to_string()],
        |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
    )
    .optional()
    .map_err(StoreError::from)
}

/// Mark prior-process running terminal rows closed at startup instead of reporting unattached sessions as live.
pub fn close_orphaned_terminals(conn: &Connection, closed_at: &str) -> Result<usize, StoreError> {
    let changed = conn.execute(
        "UPDATE project_terminals SET state = 'closed', closed_at = ?1 WHERE state = 'running'",
        rusqlite::params![closed_at],
    )?;
    Ok(changed)
}
