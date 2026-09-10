//! What `schema_migrations` records, and how a recorded version is checked against the migration this build ships at it.

use rusqlite::Connection;

use super::{Migration, MigrationError};

/// Reject incompatible histories before filling in names or applying any new migration.
pub(super) fn validate_known_versions(
    migrations: &[Migration],
    recorded: &[(u64, Option<String>)],
) -> Result<(), MigrationError> {
    for (version, _) in recorded {
        if !migrations
            .iter()
            .any(|migration| migration.version.parse::<u64>().ok() == Some(*version))
        {
            return Err(MigrationError::UnknownMigration(*version));
        }
    }
    Ok(())
}

pub(super) fn validate_order(migrations: &[Migration]) -> Result<(), MigrationError> {
    let mut previous = None;
    for migration in migrations {
        let version = migration
            .version
            .parse::<u64>()
            .map_err(|_| MigrationError::InvalidVersion(migration.version.into()))?;
        if let Some(earlier) = previous
            && version <= earlier
        {
            return Err(MigrationError::OutOfOrder(
                version.to_string(),
                earlier.to_string(),
            ));
        }
        previous = Some(version);
    }
    Ok(())
}

/// Record which file each version came from; databases written before this column carry NULL.
pub(super) fn add_name_column(conn: &Connection) -> Result<(), MigrationError> {
    let named: bool = conn.query_row(
        "SELECT COUNT(*) FROM pragma_table_info('schema_migrations') WHERE name = 'name'",
        [],
        |row| row.get::<_, i64>(0).map(|count| count > 0),
    )?;
    if !named {
        conn.execute_batch("ALTER TABLE schema_migrations ADD COLUMN name TEXT;")?;
    }
    Ok(())
}

pub(super) fn recorded_migrations(
    conn: &Connection,
) -> Result<Vec<(u64, Option<String>)>, MigrationError> {
    let mut statement = conn.prepare("SELECT version, name FROM schema_migrations")?;
    let rows = statement
        .query_map([], |row| {
            Ok((row.get::<_, i64>(0)?.max(0) as u64, row.get(1)?))
        })?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    Ok(rows)
}

/// A version this database already recorded must be the migration this build has at that version.
pub(super) fn verify_recorded(
    conn: &Connection,
    migration: &Migration,
    version: u64,
    name: Option<&str>,
    migrations: &[Migration],
    recorded: &[(u64, Option<String>)],
) -> Result<(), MigrationError> {
    let mismatch = |found: String| MigrationError::VersionMismatch {
        version: migration.version.to_owned(),
        expected: migration.name.to_owned(),
        found,
    };
    if let Some(name) = name {
        if name == migration.name {
            return Ok(());
        }
        return Err(mismatch(name.to_owned()));
    }
    // A database written before names were recorded is judged by what the migration should have created.
    let expected = Connection::open_in_memory()?;
    for applied in migrations {
        if recorded
            .iter()
            .any(|(version, _)| applied.version.parse::<u64>().ok() == Some(*version))
        {
            expected.execute_batch(applied.ddl)?;
        }
    }
    if let Some(missing) = first_missing_table(conn, &expected, migration.ddl)? {
        return Err(mismatch(format!(
            "an unnamed migration that did not create {missing}"
        )));
    }
    conn.execute(
        "UPDATE schema_migrations SET name = ?2 WHERE version = ?1 AND name IS NULL",
        rusqlite::params![version as i64, migration.name],
    )?;
    Ok(())
}

/// The first table this DDL creates that the database does not have.
fn first_missing_table(
    conn: &Connection,
    expected: &Connection,
    ddl: &str,
) -> Result<Option<String>, MigrationError> {
    for table in created_tables(ddl) {
        let survives: bool = expected.query_row(
            "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type='table' AND name=?1)",
            [&table],
            |row| row.get(0),
        )?;
        // Later, recorded migrations can legitimately drop or rename a table.
        if !survives {
            continue;
        }
        let present: i64 = conn.query_row(
            "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = ?1",
            [&table],
            |row| row.get(0),
        )?;
        if present == 0 {
            return Ok(Some(table));
        }
    }
    Ok(None)
}

/// Read the table names out of `CREATE TABLE` statements without a SQL parser.
fn created_tables(ddl: &str) -> Vec<String> {
    let lowered = ddl.to_ascii_lowercase();
    let mut names = Vec::new();
    let mut from = 0usize;
    while let Some(found) = lowered[from..].find("create table") {
        let mut at = from + found + "create table".len();
        for prefix in [" if not exists"] {
            if lowered[at..].starts_with(prefix) {
                at += prefix.len();
            }
        }
        let rest = ddl[at..].trim_start();
        let name: String = rest
            .chars()
            .take_while(|character| character.is_alphanumeric() || *character == '_')
            .collect();
        if !name.is_empty() {
            names.push(name);
        }
        from = at;
    }
    names
}
