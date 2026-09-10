use super::{Connection, StoreError, now, parse_uuid};

#[derive(Debug, Clone)]
pub struct ApprovalRow {
    pub id: uuid::Uuid,
    pub operation_id: uuid::Uuid,
    pub kind: String,
    pub resource_id: String,
    pub status: String,
    pub requested_by_device_id: Option<uuid::Uuid>,
    pub decided_by_device_id: Option<uuid::Uuid>,
    pub decision_comment: Option<String>,
    pub evidence_json: String,
}

pub fn insert_approval(
    conn: &Connection,
    operation_id: &uuid::Uuid,
    kind: &str,
    resource_id: &str,
    requested_by: Option<&uuid::Uuid>,
) -> Result<uuid::Uuid, StoreError> {
    insert_approval_with_evidence(conn, operation_id, kind, resource_id, requested_by, "{}")
}

pub fn insert_approval_with_evidence(
    conn: &Connection,
    operation_id: &uuid::Uuid,
    kind: &str,
    resource_id: &str,
    requested_by: Option<&uuid::Uuid>,
    evidence_json: &str,
) -> Result<uuid::Uuid, StoreError> {
    let id = uuid::Uuid::new_v4();
    conn.execute(
        "INSERT INTO approvals
            (id, operation_id, requested_by_device_id, requested_at, kind, resource_id, status, evidence_json)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, 'pending', ?7)",
        rusqlite::params![
            id.to_string(),
            operation_id.to_string(),
            requested_by.map(|d| d.to_string()),
            now(),
            kind,
            resource_id,
            evidence_json,
        ],
    )?;
    Ok(id)
}

pub fn decide_approval(
    conn: &Connection,
    approval_id: &uuid::Uuid,
    status: &str,
    decided_by: &uuid::Uuid,
    comment: Option<&str>,
) -> Result<(), StoreError> {
    conn.execute(
        "UPDATE approvals SET status = ?2, decided_by_device_id = ?3, decided_at = ?4, decision_comment = ?5
          WHERE id = ?1",
        rusqlite::params![
            approval_id.to_string(),
            status,
            decided_by.to_string(),
            now(),
            comment
        ],
    )?;
    Ok(())
}

pub fn approval_row(conn: &Connection, id: &uuid::Uuid) -> Result<Option<ApprovalRow>, StoreError> {
    use rusqlite::OptionalExtension;
    conn.query_row(
        "SELECT id, operation_id, kind, resource_id, status, requested_by_device_id, decided_by_device_id, decision_comment, evidence_json
           FROM approvals WHERE id = ?1",
        rusqlite::params![id.to_string()],
        |row| {
            Ok(ApprovalRow {
                id: parse_uuid(&row.get::<_, String>(0)?, 0)?,
                operation_id: parse_uuid(&row.get::<_, String>(1)?, 1)?,
                kind: row.get(2)?,
                resource_id: row.get(3)?,
                status: row.get(4)?,
                requested_by_device_id: row
                    .get::<_, Option<String>>(5)?
                    .map(|s| parse_uuid(&s, 5))
                    .transpose()?,
                decided_by_device_id: row
                    .get::<_, Option<String>>(6)?
                    .map(|s| parse_uuid(&s, 6))
                    .transpose()?,
                decision_comment: row.get(7)?,
                evidence_json: row.get(8)?,
            })
        },
    )
    .optional()
    .map_err(StoreError::from)
}

pub fn approval_for_resource(
    conn: &Connection,
    kind: &str,
    resource_id: &str,
) -> Result<Option<ApprovalRow>, StoreError> {
    use rusqlite::OptionalExtension;
    conn.query_row(
        "SELECT id, operation_id, kind, resource_id, status, requested_by_device_id,
                decided_by_device_id, decision_comment, evidence_json
           FROM approvals
          WHERE kind = ?1 AND resource_id = ?2
          ORDER BY requested_at DESC LIMIT 1",
        rusqlite::params![kind, resource_id],
        |row| {
            Ok(ApprovalRow {
                id: parse_uuid(&row.get::<_, String>(0)?, 0)?,
                operation_id: parse_uuid(&row.get::<_, String>(1)?, 1)?,
                kind: row.get(2)?,
                resource_id: row.get(3)?,
                status: row.get(4)?,
                requested_by_device_id: row
                    .get::<_, Option<String>>(5)?
                    .map(|value| parse_uuid(&value, 5))
                    .transpose()?,
                decided_by_device_id: row
                    .get::<_, Option<String>>(6)?
                    .map(|value| parse_uuid(&value, 6))
                    .transpose()?,
                decision_comment: row.get(7)?,
                evidence_json: row.get(8)?,
            })
        },
    )
    .optional()
    .map_err(StoreError::from)
}

pub fn update_approval_evidence(
    conn: &Connection,
    approval_id: &uuid::Uuid,
    evidence_json: &str,
) -> Result<(), StoreError> {
    conn.execute(
        "UPDATE approvals SET evidence_json = ?2 WHERE id = ?1",
        rusqlite::params![approval_id.to_string(), evidence_json],
    )?;
    Ok(())
}
