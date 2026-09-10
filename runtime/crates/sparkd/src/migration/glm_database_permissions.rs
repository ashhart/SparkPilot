use super::*;

fn external_probe(path: &Path, mode: &str) {
    let output = std::process::Command::new(std::env::current_exe().unwrap())
        .args([
            "--exact",
            "migration::glm_database_permissions::external_sqlite_probe",
            "--nocapture",
        ])
        .env("SPARK_SQLITE_PROBE_PATH", path)
        .env("SPARK_SQLITE_PROBE_MODE", mode)
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "external SQLite probe failed: {}{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
}

#[test]
fn external_sqlite_probe() {
    let Some(path) = std::env::var_os("SPARK_SQLITE_PROBE_PATH") else {
        return;
    };
    // Use a separate process to observe kernel locks independently of SQLite's in-process connection registry.
    let conn = Connection::open(path).unwrap();
    conn.busy_timeout(std::time::Duration::ZERO).unwrap();
    match std::env::var("SPARK_SQLITE_PROBE_MODE").unwrap().as_str() {
        "locked" => {
            let error = conn.execute_batch("BEGIN IMMEDIATE").unwrap_err();
            assert_eq!(
                error.sqlite_error_code(),
                Some(rusqlite::ErrorCode::DatabaseBusy)
            );
        }
        expected => {
            let value: i64 = conn
                .query_row("SELECT value FROM example", [], |row| row.get(0))
                .unwrap();
            assert_eq!(value, expected.parse::<i64>().unwrap());
        }
    }
    conn.close().unwrap();
}

#[test]
fn external_reader_cannot_unlink_a_live_connections_wal() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("runtime.db");
    let conn = open(&path).unwrap();
    conn.execute_batch("CREATE TABLE example(value INTEGER); INSERT INTO example VALUES(0);")
        .unwrap();
    let wal = dir.path().join("runtime.db-wal");
    let original = fs::metadata(&wal).unwrap().ino();
    external_probe(&path, "0");
    assert_eq!(
        fs::metadata(&wal)
            .expect("external reader unlinked a live WAL")
            .ino(),
        original
    );
    conn.execute_batch("UPDATE example SET value = 1").unwrap();
    external_probe(&path, "1");
}

#[test]
fn repeated_opener_preserves_existing_connections_write_lock() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("runtime.db");
    // Hold locks through a direct first connection to isolate the effect of reopening the same database.
    let conn = Connection::open(&path).unwrap();
    conn.execute_batch(
        "PRAGMA journal_mode=WAL; CREATE TABLE example(value INTEGER); \
         INSERT INTO example VALUES(0); BEGIN IMMEDIATE; UPDATE example SET value = 1;",
    )
    .unwrap();
    let second = open(&path).unwrap();
    external_probe(&path, "locked");
    drop(second);
    external_probe(&path, "locked");
    conn.execute_batch("COMMIT").unwrap();
    external_probe(&path, "1");
}

#[test]
fn database_and_sidecar_symlinks_are_refused_without_chmodding_targets() {
    for name in ["runtime.db", "runtime.db-wal", "runtime.db-shm"] {
        let dir = tempfile::tempdir().unwrap();
        let victim = dir.path().join("unrelated");
        fs::write(&victim, "untouched").unwrap();
        fs::set_permissions(&victim, fs::Permissions::from_mode(0o644)).unwrap();
        std::os::unix::fs::symlink(&victim, dir.path().join(name)).unwrap();
        assert!(open(&dir.path().join("runtime.db")).is_err(), "{name}");
        assert_eq!(fs::read_to_string(&victim).unwrap(), "untouched");
        assert_eq!(fs::metadata(&victim).unwrap().mode() & 0o777, 0o644);
    }
}

#[test]
fn database_and_wal_are_owner_only() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("runtime.db");
    fs::write(&path, b"").unwrap();
    fs::set_permissions(&path, fs::Permissions::from_mode(0o644)).unwrap();
    let conn = open(&path).unwrap();
    conn.execute_batch("CREATE TABLE example (id INTEGER);")
        .unwrap();
    for name in ["runtime.db-wal", "runtime.db-shm"] {
        fs::set_permissions(dir.path().join(name), fs::Permissions::from_mode(0o644)).unwrap();
    }
    let _reopened = open(&path).unwrap();
    for name in ["runtime.db", "runtime.db-wal", "runtime.db-shm"] {
        assert_eq!(
            fs::metadata(dir.path().join(name))
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o600,
            "{name}"
        );
    }
}
