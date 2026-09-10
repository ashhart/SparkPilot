use super::{Connection, StoreError, parse_uuid};

#[derive(Debug, Clone)]
pub struct BuildArtifactRow {
    pub id: uuid::Uuid,
    pub build_id: uuid::Uuid,
    pub operation_id: uuid::Uuid,
    pub project_id: uuid::Uuid,
    pub worker_id: uuid::Uuid,
    pub claim_generation: i64,
    pub kind: String,
    pub relative_path: String,
    pub sha256: String,
    pub size_bytes: u64,
    pub created_at: String,
}

pub fn insert_build_artifact(conn: &Connection, row: &BuildArtifactRow) -> Result<(), StoreError> {
    conn.execute(
        "INSERT INTO build_artifacts
            (id, build_id, operation_id, project_id, worker_id, claim_generation,
             kind, relative_path, sha256, size_bytes, created_at, metadata_json)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, '{}')",
        rusqlite::params![
            row.id.to_string(),
            row.build_id.to_string(),
            row.operation_id.to_string(),
            row.project_id.to_string(),
            row.worker_id.to_string(),
            row.claim_generation,
            row.kind,
            row.relative_path,
            row.sha256,
            i64::try_from(row.size_bytes)
                .map_err(|_| StoreError::Sqlite("artifact too large".into()))?,
            row.created_at,
        ],
    )?;
    Ok(())
}

pub fn build_artifacts(
    conn: &Connection,
    build_id: &uuid::Uuid,
    claim_generation: i64,
) -> Result<Vec<BuildArtifactRow>, StoreError> {
    let mut statement = conn.prepare(
        "SELECT id, build_id, operation_id, project_id, worker_id, claim_generation,
                kind, relative_path, sha256, size_bytes, created_at
           FROM build_artifacts
          WHERE build_id = ?1 AND claim_generation = ?2 ORDER BY id",
    )?;
    statement
        .query_map(
            rusqlite::params![build_id.to_string(), claim_generation],
            |row| {
                let size: i64 = row.get(9)?;
                Ok(BuildArtifactRow {
                    id: parse_uuid(&row.get::<_, String>(0)?, 0)?,
                    build_id: parse_uuid(&row.get::<_, String>(1)?, 1)?,
                    operation_id: parse_uuid(&row.get::<_, String>(2)?, 2)?,
                    project_id: parse_uuid(&row.get::<_, String>(3)?, 3)?,
                    worker_id: parse_uuid(&row.get::<_, String>(4)?, 4)?,
                    claim_generation: row.get(5)?,
                    kind: row.get(6)?,
                    relative_path: row.get(7)?,
                    sha256: row.get(8)?,
                    size_bytes: u64::try_from(size).map_err(|error| {
                        rusqlite::Error::FromSqlConversionFailure(
                            9,
                            rusqlite::types::Type::Integer,
                            Box::new(error),
                        )
                    })?,
                    created_at: row.get(10)?,
                })
            },
        )?
        .collect::<Result<Vec<_>, _>>()
        .map_err(StoreError::from)
}

pub fn build_artifact_usage(
    conn: &Connection,
    build_id: &uuid::Uuid,
    claim_generation: i64,
) -> Result<(u64, u64), StoreError> {
    let (count, total): (i64, i64) = conn.query_row(
        "SELECT COUNT(*), COALESCE(SUM(size_bytes), 0)
           FROM build_artifacts WHERE build_id = ?1 AND claim_generation = ?2",
        rusqlite::params![build_id.to_string(), claim_generation],
        |row| Ok((row.get(0)?, row.get(1)?)),
    )?;
    Ok((count.max(0) as u64, total.max(0) as u64))
}

pub fn delete_build_artifacts(
    conn: &Connection,
    build_id: &uuid::Uuid,
    claim_generation: i64,
) -> Result<(), StoreError> {
    conn.execute(
        "DELETE FROM build_artifacts WHERE build_id = ?1 AND claim_generation = ?2",
        rusqlite::params![build_id.to_string(), claim_generation],
    )?;
    Ok(())
}

pub fn build_artifact(
    conn: &Connection,
    build_id: &uuid::Uuid,
    artifact_id: &uuid::Uuid,
) -> Result<Option<BuildArtifactRow>, StoreError> {
    use rusqlite::OptionalExtension;
    conn.query_row(
        "SELECT id, build_id, operation_id, project_id, worker_id, claim_generation,
                kind, relative_path, sha256, size_bytes, created_at
           FROM build_artifacts WHERE build_id = ?1 AND id = ?2",
        rusqlite::params![build_id.to_string(), artifact_id.to_string()],
        |row| {
            let size: i64 = row.get(9)?;
            Ok(BuildArtifactRow {
                id: parse_uuid(&row.get::<_, String>(0)?, 0)?,
                build_id: parse_uuid(&row.get::<_, String>(1)?, 1)?,
                operation_id: parse_uuid(&row.get::<_, String>(2)?, 2)?,
                project_id: parse_uuid(&row.get::<_, String>(3)?, 3)?,
                worker_id: parse_uuid(&row.get::<_, String>(4)?, 4)?,
                claim_generation: row.get(5)?,
                kind: row.get(6)?,
                relative_path: row.get(7)?,
                sha256: row.get(8)?,
                size_bytes: u64::try_from(size).map_err(|error| {
                    rusqlite::Error::FromSqlConversionFailure(
                        9,
                        rusqlite::types::Type::Integer,
                        Box::new(error),
                    )
                })?,
                created_at: row.get(10)?,
            })
        },
    )
    .optional()
    .map_err(StoreError::from)
}
