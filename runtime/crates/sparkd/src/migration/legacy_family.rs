//! Reconcile the two known, unpublished family-preview histories without replaying their DDL.
use super::*;

/// Only the complete, structurally matching preview is eligible; unknown histories remain errors.
pub(super) fn reconcile(
    conn: &mut Connection,
    database: Option<&Path>,
) -> Result<(Vec<String>, Option<PathBuf>), MigrationError> {
    let recorded = recorded_migrations(conn)?;
    let latest = recorded
        .iter()
        .map(|(version, _)| *version)
        .max()
        .unwrap_or(0);
    if !matches!(latest, 33 | 34) || !table_exists(conn, "household_members")? {
        return Ok((Vec::new(), None));
    }
    let invalid = || MigrationError::VersionMismatch {
        version: format!("{latest:04}"),
        expected: "complete family preview schema 33 or 34".into(),
        found: "an unrecognised preview history or schema".into(),
    };
    if recorded.len() != latest as usize {
        return Err(invalid());
    }
    for version in 1..=latest {
        let Some((_, name)) = recorded.iter().find(|(found, _)| *found == version) else {
            return Err(invalid());
        };
        let expected = match version {
            33 => "0033_household",
            34 => "0034_private_remote_only",
            _ => MIGRATIONS[(version - 1) as usize].name,
        };
        if name.as_deref().is_some_and(|name| name != expected) {
            return Err(invalid());
        }
    }
    // Compare every migration-owned object, including constraints and triggers, before touching metadata.
    let expected = Connection::open_in_memory()?;
    for migration in MIGRATIONS.iter().take(32) {
        expected.execute_batch(migration.ddl)?;
    }
    expected.execute_batch(include_str!("../../migrations/0037_household.sql"))?;
    if latest == 34 {
        expected.execute_batch(include_str!(
            "../../migrations/0038_private_remote_only.sql"
        ))?;
    }
    if schema_objects(conn)? != schema_objects(&expected)? {
        return Err(invalid());
    }
    let backup = match database {
        Some(path) => Some(take_recovery_point(conn, path, "family-preview-reconcile")?),
        None if is_file_backed(conn) => {
            return Err(MigrationError::RecoveryPointRequired(
                "family-preview-reconcile".into(),
            ));
        }
        None => None,
    };
    let tx = conn.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
    let mut applied = Vec::new();
    // Preserve the original application timestamps, and record the exact preview files they came from.
    tx.execute_batch(
        "CREATE TABLE IF NOT EXISTS migration_preview_reconciliation (
        original_version INTEGER PRIMARY KEY, original_name TEXT NOT NULL,
        canonical_version INTEGER NOT NULL, applied_at TEXT NOT NULL
    );",
    )?;
    for (old, name, new, canonical) in [
        (33, "0033_household", 37, "0037_household"),
        (
            34,
            "0034_private_remote_only",
            38,
            "0038_private_remote_only",
        ),
    ] {
        if old > latest {
            continue;
        }
        tx.execute(
            "INSERT INTO migration_preview_reconciliation
            SELECT version, ?2, ?3, applied_at FROM schema_migrations WHERE version = ?1",
            rusqlite::params![old, name, new],
        )?;
        tx.execute(
            "UPDATE schema_migrations SET version = ?2, name = ?3 WHERE version = ?1",
            rusqlite::params![old, new, canonical],
        )?;
    }
    for migration in MIGRATIONS
        .iter()
        .filter(|migration| matches!(migration.version, "0033" | "0035" | "0036"))
    {
        tx.execute_batch(migration.ddl)?;
        tx.execute(
            "INSERT INTO schema_migrations (version, name, applied_at)
            VALUES (?1, ?2, strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))",
            rusqlite::params![migration.version, migration.name],
        )?;
        applied.push(migration.version.to_owned());
    }
    applied.push("0037".into());
    if latest == 34 {
        applied.push("0038".into());
    }
    tx.commit()?;
    Ok((applied, backup))
}

fn table_exists(conn: &Connection, name: &str) -> rusqlite::Result<bool> {
    conn.query_row(
        "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type='table' AND name=?1)",
        [name],
        |row| row.get(0),
    )
}

fn schema_objects(conn: &Connection) -> rusqlite::Result<Vec<(String, String, String)>> {
    let mut query = conn.prepare(
        "SELECT type, name, sql FROM sqlite_master
        WHERE sql IS NOT NULL AND name NOT LIKE 'sqlite_%' AND name != 'schema_migrations'
        ORDER BY type, name",
    )?;
    query
        .query_map([], |row| {
            let sql: String = row.get(2)?;
            Ok((
                row.get(0)?,
                row.get(1)?,
                sql.split_whitespace().collect::<Vec<_>>().join(" "),
            ))
        })?
        .collect()
}
