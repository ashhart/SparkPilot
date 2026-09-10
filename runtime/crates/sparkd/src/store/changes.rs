use super::{Connection, StoreError, now, parse_uuid};

// Persist agent change proposals and their approvals.

#[derive(Debug, Clone, serde::Serialize)]
pub struct ChangeRow {
    pub id: uuid::Uuid,
    pub project_id: uuid::Uuid,
    pub operation_id: uuid::Uuid,
    pub worktree_branch: String,
    pub base_commit: String,
    pub task: String,
    pub status: String,
    pub diff_summary_json: String,
    pub test_summary_json: String,
    pub audit_json: String,
    pub head_commit: Option<String>,
    pub protected_head_commit: Option<String>,
    pub review_digest: Option<String>,
    pub review_evidence_json: String,
    pub merged_commit: Option<String>,
    pub created_at: String,
    pub updated_at: String,
}

pub fn insert_change(conn: &Connection, change: &ChangeRow) -> Result<(), StoreError> {
    conn.execute(
        "INSERT INTO changes
            (id, project_id, operation_id, worktree_branch, base_commit, task, status,
             diff_summary_json, test_summary_json, audit_json, head_commit,
             protected_head_commit, review_digest, review_evidence_json, merged_commit,
             created_at, updated_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?16)",
        rusqlite::params![
            change.id.to_string(),
            change.project_id.to_string(),
            change.operation_id.to_string(),
            change.worktree_branch,
            change.base_commit,
            change.task,
            change.status,
            change.diff_summary_json,
            change.test_summary_json,
            change.audit_json,
            change.head_commit,
            change.protected_head_commit,
            change.review_digest,
            change.review_evidence_json,
            change.merged_commit,
            now(),
        ],
    )?;
    Ok(())
}

pub fn change_row(conn: &Connection, id: &uuid::Uuid) -> Result<Option<ChangeRow>, StoreError> {
    use rusqlite::OptionalExtension;
    conn.query_row(
        "SELECT id, project_id, operation_id, worktree_branch, base_commit, task, status,
                diff_summary_json, test_summary_json, audit_json, head_commit,
                protected_head_commit, review_digest, review_evidence_json, merged_commit,
                created_at, updated_at
           FROM changes WHERE id = ?1",
        rusqlite::params![id.to_string()],
        map_change,
    )
    .optional()
    .map_err(StoreError::from)
}

fn map_change(row: &rusqlite::Row<'_>) -> rusqlite::Result<ChangeRow> {
    Ok(ChangeRow {
        id: parse_uuid(&row.get::<_, String>(0)?, 0)?,
        project_id: parse_uuid(&row.get::<_, String>(1)?, 1)?,
        operation_id: parse_uuid(&row.get::<_, String>(2)?, 2)?,
        worktree_branch: row.get(3)?,
        base_commit: row.get(4)?,
        task: row.get(5)?,
        status: row.get(6)?,
        diff_summary_json: row.get(7)?,
        test_summary_json: row.get(8)?,
        audit_json: row.get(9)?,
        head_commit: row.get(10)?,
        protected_head_commit: row.get(11)?,
        review_digest: row.get(12)?,
        review_evidence_json: row.get(13)?,
        merged_commit: row.get(14)?,
        created_at: row.get(15)?,
        updated_at: row.get(16)?,
    })
}

pub fn change_rows(
    conn: &Connection,
    project_id: &uuid::Uuid,
) -> Result<Vec<ChangeRow>, StoreError> {
    let mut stmt = conn
        .prepare("SELECT id, project_id, operation_id, worktree_branch, base_commit, task, status, diff_summary_json, test_summary_json, audit_json, head_commit, protected_head_commit, review_digest, review_evidence_json, merged_commit, created_at, updated_at FROM changes WHERE project_id = ?1 ORDER BY created_at DESC")?;
    let rows = stmt
        .query_map([project_id.to_string()], map_change)?
        .collect::<Result<Vec<_>, _>>()?;
    Ok(rows)
}

pub fn set_change_branch(
    conn: &Connection,
    id: &uuid::Uuid,
    branch: &str,
) -> Result<(), StoreError> {
    conn.execute(
        "UPDATE changes SET worktree_branch = ?2, updated_at = ?3 WHERE id = ?1",
        rusqlite::params![id.to_string(), branch, now()],
    )?;
    Ok(())
}

pub fn update_change_status(
    conn: &Connection,
    id: &uuid::Uuid,
    status: &str,
) -> Result<(), StoreError> {
    conn.execute(
        "UPDATE changes SET status = ?2, updated_at = ?3 WHERE id = ?1",
        rusqlite::params![id.to_string(), status, now()],
    )?;
    Ok(())
}

pub fn update_change_summaries(
    conn: &Connection,
    id: &uuid::Uuid,
    diff_summary_json: &str,
    test_summary_json: &str,
    audit_json: &str,
) -> Result<(), StoreError> {
    conn.execute(
        "UPDATE changes SET diff_summary_json = ?2, test_summary_json = ?3, audit_json = ?4, updated_at = ?5
          WHERE id = ?1",
        rusqlite::params![
            id.to_string(),
            diff_summary_json,
            test_summary_json,
            audit_json,
            now()
        ],
    )?;
    Ok(())
}

pub fn set_change_review_evidence(
    conn: &Connection,
    id: &uuid::Uuid,
    base_commit: &str,
    head_commit: &str,
    protected_head_commit: &str,
    review_digest: &str,
    review_evidence_json: &str,
) -> Result<bool, StoreError> {
    let changed = conn.execute(
        "UPDATE changes
            SET base_commit = ?2, head_commit = ?3, protected_head_commit = ?4,
                review_digest = ?5, review_evidence_json = ?6, status = 'review',
                updated_at = ?7
          WHERE id = ?1 AND status IN ('creating','planning','editing')",
        rusqlite::params![
            id.to_string(),
            base_commit,
            head_commit,
            protected_head_commit,
            review_digest,
            review_evidence_json,
            now(),
        ],
    )?;
    Ok(changed == 1)
}

pub fn set_change_approved(conn: &Connection, id: &uuid::Uuid) -> Result<bool, StoreError> {
    let changed = conn.execute(
        "UPDATE changes SET status = 'approved', updated_at = ?2
          WHERE id = ?1 AND status = 'review'",
        rusqlite::params![id.to_string(), now()],
    )?;
    Ok(changed == 1)
}

pub fn set_change_merged(
    conn: &Connection,
    id: &uuid::Uuid,
    merged_commit: &str,
) -> Result<bool, StoreError> {
    let changed = conn.execute(
        "UPDATE changes SET status = 'merged', merged_commit = ?2, updated_at = ?3
          WHERE id = ?1 AND status IN ('approved','merged')",
        rusqlite::params![id.to_string(), merged_commit, now()],
    )?;
    Ok(changed == 1)
}

/// One audited agent tool call (§42.5).
pub fn insert_agent_call(
    conn: &Connection,
    change_id: &uuid::Uuid,
    tool: &str,
    arguments_json: &str,
    outcome: &str,
) -> Result<(), StoreError> {
    conn.execute(
        "INSERT INTO agent_calls (change_id, tool, arguments_json, outcome, at)
         VALUES (?1, ?2, ?3, ?4, ?5)",
        rusqlite::params![change_id.to_string(), tool, arguments_json, outcome, now()],
    )?;
    Ok(())
}

pub fn agent_calls(
    conn: &Connection,
    change_id: &uuid::Uuid,
) -> Result<Vec<(String, String, String)>, StoreError> {
    let mut stmt = conn.prepare(
        "SELECT tool, arguments_json, outcome FROM agent_calls WHERE change_id = ?1 ORDER BY id",
    )?;
    let rows = stmt
        .query_map([change_id.to_string()], |row| {
            Ok((row.get(0)?, row.get(1)?, row.get(2)?))
        })?
        .collect::<Result<Vec<_>, _>>()?;
    Ok(rows)
}
