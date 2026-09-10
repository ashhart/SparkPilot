//! Apply forward-only transactional migrations with per-connection pragmas and recovery points before destructive steps.

use std::fs;
use std::io;
use std::os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};

use rusqlite::Connection;
use thiserror::Error;

/// Declare migration effects explicitly and test additive declarations against SQL rather than inferring safety at runtime.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MigrationKind {
    /// Add schema objects without altering existing rows.
    Additive,
    /// Drops or rewrites something that holds data.
    Destructive,
}

/// One migration in apply order.
#[derive(Debug, Clone, Copy)]
pub struct Migration {
    pub version: &'static str,
    /// The file this migration came from, recorded so a renumber is loud rather than silent.
    pub name: &'static str,
    pub kind: MigrationKind,
    pub ddl: &'static str,
}

/// Name every migration after its file so the recorded name and the shipped file cannot drift apart.
macro_rules! migrations {
    ($(($version:literal, $file:literal, $kind:ident)),+ $(,)?) => {
        &[$(Migration {
            version: $version,
            name: $file,
            kind: MigrationKind::$kind,
            ddl: include_str!(concat!("../migrations/", $file, ".sql")),
        }),+]
    };
}

/// Ordered migrations from the versioned runtime SQL directory.
pub const MIGRATIONS: &[Migration] = migrations![
    ("0001", "0001_initial", Additive),
    ("0002", "0002_profile_measurements", Additive),
    ("0003", "0003_cluster_state", Additive),
    ("0004", "0004_agents", Additive),
    ("0005", "0005_builds", Additive),
    ("0006", "0006_peer_facts", Additive),
    ("0007", "0007_user_presence_keys", Additive),
    ("0008", "0008_appliance_settings", Additive),
    ("0009", "0009_optional_services", Additive),
    ("0010", "0010_catalogue_refresh", Additive),
    ("0011", "0011_presence_and_terminals", Additive),
    ("0012", "0012_build_claims", Additive),
    ("0013", "0013_external_fabric_evidence", Additive),
    ("0014", "0014_workload_adoption", Additive),
    ("0015", "0015_remote_envelope_replay", Additive),
    ("0016", "0016_pairing_join_codes", Additive),
    ("0017", "0017_telemetry_history", Additive),
    ("0018", "0018_project_review_evidence", Additive),
    ("0019", "0019_build_worker_protocol", Additive),
    ("0020", "0020_cluster_coordination", Additive),
    ("0021", "0021_join_code_attempts", Additive),
    ("0022", "0022_owner_delete_guard", Additive),
    ("0023", "0023_owner_transition_guard", Additive),
    ("0024", "0024_inference_requests", Additive),
    ("0025", "0025_inference_pool_policies", Additive),
    ("0026", "0026_inference_reservations", Additive),
    ("0027", "0027_inference_pool_indexes", Additive),
    ("0028", "0028_warmup_schedules", Additive),
    ("0029", "0029_pool_router_identities", Additive),
    ("0030", "0030_automations", Additive),
    ("0031", "0031_guest_shared_access", Additive),
    ("0032", "0032_profile_measurement_environment", Additive),
    ("0033", "0033_web_call_reservations", Additive),
    ("0035", "0035_operation_lease_fence", Additive),
    ("0036", "0036_automation_run_in_flight", Additive),
    ("0037", "0037_household", Additive),
    ("0038", "0038_private_remote_only", Destructive),
    ("0039", "0039_retention_expiry_indexes", Additive),
    ("0040", "0040_development_workspaces", Additive),
    ("0041", "0041_model_idle_timeouts", Additive),
];

#[derive(Debug, Error)]
pub enum MigrationError {
    #[error("database file: {0}")]
    Io(#[from] io::Error),
    #[error("SQLite error: {0}")]
    Sqlite(#[from] rusqlite::Error),
    #[error("migration version is not numeric: {0}")]
    InvalidVersion(String),
    #[error("migrations are out of order: {0} > {1}")]
    OutOfOrder(String, String),
    #[error(
        "this database contains migration {0}, which this runtime does not recognise; use a compatible runtime"
    )]
    UnknownMigration(u64),
    #[error(
        "this database recorded migration {version} as {found}, but this build ships {expected} there;          the database was written by an incompatible build and must be restored from a recovery point or recreated"
    )]
    VersionMismatch {
        version: String,
        expected: String,
        found: String,
    },
    #[error(
        "migration {version} ({name}) has never been applied to this database, but the later migration {recorded} has;          the database was written by an incompatible build and must be restored from a recovery point or recreated"
    )]
    SkippedMigration {
        version: String,
        name: String,
        recorded: String,
    },
    #[error("no recovery point could be secured before migration {version}: {reason}")]
    BackupUnavailable { version: String, reason: String },
    #[error("{database} is not the file this connection has open ({open})")]
    DatabaseMismatch { database: PathBuf, open: String },
    #[error(
        "migration {0} is destructive and this database is on disk: use migrate_with_recovery_point"
    )]
    RecoveryPointRequired(String),
}

/// What a migration run did.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MigrationOutcome {
    /// Versions applied in this call, in order.
    pub applied: Vec<String>,
    /// The recovery point taken before the first destructive migration.
    pub recovery_point: Option<PathBuf>,
}

/// Open (or create) the SQLite database and apply connection PRAGMAs.
pub fn open(path: &Path) -> Result<Connection, MigrationError> {
    // Never open and close existing SQLite files outside SQLite because POSIX descriptor closure releases this process's locks on their inode.
    match fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW)
        .open(path)
    {
        Ok(file) => drop(file),
        Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {}
        Err(error) => return Err(error.into()),
    }
    let parent = path
        .parent()
        .filter(|parent| !parent.as_os_str().is_empty())
        .unwrap_or(Path::new("."));
    let canonical = parent.canonicalize()?.join(
        path.file_name()
            .ok_or_else(|| io::Error::other("database filename is missing"))?,
    );
    owner_only_without_opening(&canonical, false)?;
    // Tighten existing WAL modes without opening SHM descriptors that could release another connection's locks.
    for suffix in ["-wal", "-shm"] {
        let mut sidecar = canonical.as_os_str().to_os_string();
        sidecar.push(suffix);
        owner_only_without_opening(Path::new(&sidecar), true)?;
    }
    let conn = Connection::open_with_flags(
        canonical,
        rusqlite::OpenFlags::SQLITE_OPEN_READ_WRITE | rusqlite::OpenFlags::SQLITE_OPEN_NOFOLLOW,
    )?;
    conn.pragma_update(None, "journal_mode", "WAL")?;
    conn.pragma_update(None, "foreign_keys", "ON")?;
    conn.pragma_update(None, "busy_timeout", 5000)?;
    Ok(conn)
}

fn owner_only_without_opening(path: &Path, missing_allowed: bool) -> io::Result<()> {
    match fs::symlink_metadata(path) {
        Ok(metadata) if metadata.is_file() => {}
        Ok(_) => {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                format!("SQLite entry is not a regular file: {}", path.display()),
            ));
        }
        Err(error) if missing_allowed && error.kind() == io::ErrorKind::NotFound => {
            return Ok(());
        }
        Err(error) => return Err(error),
    }
    // Change modes with AT_SYMLINK_NOFOLLOW without opening data descriptors that could invalidate SQLite locks.
    match nix::sys::stat::fchmodat(
        nix::fcntl::AT_FDCWD,
        path,
        nix::sys::stat::Mode::S_IRUSR | nix::sys::stat::Mode::S_IWUSR,
        nix::sys::stat::FchmodatFlags::NoFollowSymlink,
    ) {
        Ok(()) => Ok(()),
        Err(nix::errno::Errno::ENOENT) if missing_allowed => Ok(()),
        Err(error) => Err(io::Error::from_raw_os_error(error as i32)),
    }
}

/// Apply transactional migrations without backup only when no pending destructive step targets an on-disk database.
pub fn migrate(conn: &mut Connection) -> Result<Vec<String>, MigrationError> {
    apply(conn, MIGRATIONS, None).map(|outcome| outcome.applied)
}

/// Take an online backup including committed WAL rows immediately before the first destructive migration.
pub fn migrate_with_recovery_point(
    conn: &mut Connection,
    database: &Path,
) -> Result<MigrationOutcome, MigrationError> {
    ensure_same_file(conn, database)?;
    sweep_stale_staged(database);
    apply(conn, MIGRATIONS, Some(database))
}

/// Verify the supplied database path matches the connection's open file before producing recovery evidence.
fn ensure_same_file(conn: &Connection, database: &Path) -> Result<(), MigrationError> {
    let open = conn.path().unwrap_or_default().to_owned();
    let mismatch = || MigrationError::DatabaseMismatch {
        database: database.to_path_buf(),
        open: open.clone(),
    };
    if open.is_empty() {
        return Err(mismatch());
    }
    match (fs::metadata(&open), fs::metadata(database)) {
        (Ok(left), Ok(right)) if left.dev() == right.dev() && left.ino() == right.ino() => Ok(()),
        (Ok(_), Ok(_)) => Err(mismatch()),
        _ => {
            let canonical = |path: &Path| {
                path.parent()
                    .and_then(|parent| parent.canonicalize().ok())
                    .map(|parent| parent.join(path.file_name().unwrap_or_default()))
            };
            if canonical(Path::new(&open)) == canonical(database) {
                Ok(())
            } else {
                Err(mismatch())
            }
        }
    }
}

/// Sweep only exact regular staged aliases inside the verified private recovery directory without following links.
fn sweep_stale_staged(database: &Path) {
    let directory = recovery_directory(database);
    // Do not create recovery directories merely to sweep nonexistent staged aliases.
    if fs::symlink_metadata(&directory).is_err() || prepare_recovery_directory(&directory).is_err()
    {
        return;
    }
    let Some(stem) = database.file_stem().and_then(|stem| stem.to_str()) else {
        return;
    };
    let prefix = format!(".{stem}-before-");
    let Ok(entries) = fs::read_dir(&directory) else {
        return;
    };
    for entry in entries.flatten() {
        let name = entry.file_name();
        let Some(name) = name.to_str() else { continue };
        if !name.starts_with(&prefix) || !name.ends_with(".staged") {
            continue;
        }
        let path = directory.join(name);
        match fs::symlink_metadata(&path) {
            Ok(metadata) if metadata.is_file() => {
                let _ = fs::remove_file(&path);
            }
            _ => continue,
        }
    }
}

fn apply(
    conn: &mut Connection,
    migrations: &[Migration],
    database: Option<&Path>,
) -> Result<MigrationOutcome, MigrationError> {
    recorded::validate_order(migrations)?;
    conn.execute_batch(
        "CREATE TABLE IF NOT EXISTS schema_migrations (
            version INTEGER PRIMARY KEY,
            applied_at TEXT NOT NULL
        );",
    )?;
    add_name_column(conn)?;
    let (reconciled, recovery_point) = if migrations
        .iter()
        .any(|migration| migration.name == "0038_private_remote_only")
    {
        legacy_family::reconcile(conn, database)?
    } else {
        (Vec::new(), None)
    };
    let recorded = recorded_migrations(conn)?;
    recorded::validate_known_versions(migrations, &recorded)?;
    let latest_recorded = recorded.iter().map(|(version, _)| *version).max();

    let mut outcome = MigrationOutcome {
        applied: reconciled,
        recovery_point,
    };
    let mut previous: Option<u64> = None;
    for migration in migrations.iter().copied() {
        let version: u64 = migration
            .version
            .parse()
            .map_err(|_| MigrationError::InvalidVersion(migration.version.to_owned()))?;
        // Gaps are ordinary while parallel branches are open; going backwards never is.
        if previous.is_some_and(|earlier| version <= earlier) {
            return Err(MigrationError::OutOfOrder(
                version.to_string(),
                previous.unwrap_or_default().to_string(),
            ));
        }
        previous = Some(version);

        if let Some((_, name)) = recorded.iter().find(|(recorded, _)| *recorded == version) {
            verify_recorded(
                conn,
                &migration,
                version,
                name.as_deref(),
                migrations,
                &recorded,
            )?;
            continue;
        }
        // Applying a migration underneath one that already ran would leave the schema in an order nobody tested.
        if let Some(latest) = latest_recorded.filter(|latest| *latest > version) {
            return Err(MigrationError::SkippedMigration {
                version: migration.version.to_owned(),
                name: migration.name.to_owned(),
                recorded: format!("{latest:04}"),
            });
        }

        // Create recovery evidence before any destructive DDL begins.
        if migration.kind == MigrationKind::Destructive && outcome.recovery_point.is_none() {
            match database {
                Some(database) => {
                    outcome.recovery_point =
                        Some(take_recovery_point(conn, database, migration.version)?);
                }
                None if is_file_backed(conn) => {
                    return Err(MigrationError::RecoveryPointRequired(
                        migration.version.to_owned(),
                    ));
                }
                None => {}
            }
        }

        let tx = conn.transaction()?;
        tx.execute_batch(migration.ddl)?;
        tx.execute(
            "INSERT INTO schema_migrations (version, name, applied_at)
             VALUES (?1, ?2, strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))",
            rusqlite::params![version as i64, migration.name],
        )?;
        tx.commit()?;
        outcome.applied.push(migration.version.to_owned());
    }
    Ok(outcome)
}

/// Where recovery points live: a directory only the owner can enter.
fn recovery_directory(database: &Path) -> PathBuf {
    database
        .parent()
        .unwrap_or_else(|| Path::new("."))
        .join("recovery-points")
}

/// Create recovery directories with mode 0700 from birth and reject existing symlinks or nondirectories.
fn prepare_recovery_directory(directory: &Path) -> io::Result<()> {
    match fs::DirBuilder::new().mode(0o700).create(directory) {
        Ok(()) => {
            // Sync the parent entry in addition to the child's contents.
            if let Some(parent) = directory.parent() {
                sync(parent)?;
            }
            return Ok(());
        }
        Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {}
        Err(error) => return Err(error),
    }
    let metadata = fs::symlink_metadata(directory)?;
    if !metadata.is_dir() {
        return Err(io::Error::new(
            io::ErrorKind::NotADirectory,
            format!("{} is not a directory", directory.display()),
        ));
    }
    fs::set_permissions(directory, fs::Permissions::from_mode(0o700))
}

/// Write backups into private synced inodes and publish with nonreplacing links so existing recovery points survive.
fn take_recovery_point(
    conn: &Connection,
    database: &Path,
    version: &str,
) -> Result<PathBuf, MigrationError> {
    let fail = |reason: String| MigrationError::BackupUnavailable {
        version: version.to_owned(),
        reason,
    };
    let directory = recovery_directory(database);
    prepare_recovery_directory(&directory).map_err(|error| fail(error.to_string()))?;

    let stem = database
        .file_stem()
        .and_then(|stem| stem.to_str())
        .unwrap_or("database");
    let staged = directory.join(format!(".{stem}-before-{version}.staged"));
    // Treat unpublished staging leftovers as incomplete snapshots, never recovery points.
    let _ = fs::remove_file(&staged);

    // Create the snapshot inode privately before SQLite initializes it so umask cannot expose backup data.
    fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&staged)
        .map_err(|error| fail(error.to_string()))?;

    let outcome = write_snapshot(conn, &staged);
    if let Err(reason) = outcome {
        let _ = fs::remove_file(&staged);
        return Err(fail(reason));
    }

    let published = match publish(&staged, &directory, stem, version) {
        Ok(published) => published,
        Err(error) => {
            let _ = remove_staged(&staged);
            return Err(fail(error.to_string()));
        }
    };

    // After publishing and syncing recovery evidence, defer failed staged-alias cleanup without rejecting a safe migration.
    sync(&directory).map_err(|error| fail(error.to_string()))?;
    let _ = remove_staged(&staged);
    Ok(published)
}

/// Remove staging aliases best-effort only after their recovery point is durably linked.
fn remove_staged(staged: &Path) -> io::Result<()> {
    #[cfg(test)]
    if tests::staged_cleanup_is_refused() {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "staged cleanup refused",
        ));
    }
    fs::remove_file(staged)
}

/// Choose the first unused recovery name with nonreplacing link so retries preserve earlier snapshots.
fn publish(staged: &Path, directory: &Path, stem: &str, version: &str) -> io::Result<PathBuf> {
    for attempt in 0..MAX_RECOVERY_POINTS {
        let name = match attempt {
            0 => format!("{stem}-before-{version}.db"),
            _ => format!("{stem}-before-{version}.retry-{attempt}.db"),
        };
        let candidate = directory.join(name);
        match fs::hard_link(staged, &candidate) {
            Ok(()) => return Ok(candidate),
            Err(error) if error.kind() == io::ErrorKind::AlreadyExists => continue,
            Err(error) => return Err(error),
        }
    }
    Err(io::Error::new(
        io::ErrorKind::AlreadyExists,
        format!("{MAX_RECOVERY_POINTS} recovery points already exist for migration {version}"),
    ))
}

/// Bound accumulated recovery points while allowing ordinary migration retries.
const MAX_RECOVERY_POINTS: u32 = 16;

/// Use SQLite online backup to include committed WAL pages without taking the source offline.
fn write_snapshot(conn: &Connection, staged: &Path) -> Result<(), String> {
    let mut destination = Connection::open(staged).map_err(|error| error.to_string())?;
    {
        let backup = rusqlite::backup::Backup::new(conn, &mut destination)
            .map_err(|error| error.to_string())?;
        backup
            .run_to_completion(64, std::time::Duration::from_millis(0), None)
            .map_err(|error| error.to_string())?;
    }
    destination
        .pragma_update(None, "wal_checkpoint", "TRUNCATE")
        .ok();
    destination
        .close()
        .map_err(|(_, error)| error.to_string())?;
    sync(staged).map_err(|error| error.to_string())
}

fn sync(path: &Path) -> io::Result<()> {
    fs::File::open(path)?.sync_all()
}

/// Whether this connection is backed by a file rather than memory.
fn is_file_backed(conn: &Connection) -> bool {
    conn.path().is_some_and(|path| {
        !path.is_empty() && path != ":memory:" && !path.starts_with("file::memory:")
    })
}

#[path = "migration/legacy_family.rs"]
mod legacy_family;

#[path = "migration/recorded.rs"]
mod recorded;
use recorded::{add_name_column, recorded_migrations, verify_recorded};

#[cfg(test)]
#[path = "migration/tests.rs"]
mod tests;

#[cfg(test)]
#[path = "migration/glm_database_permissions.rs"]
mod glm_database_permissions;
