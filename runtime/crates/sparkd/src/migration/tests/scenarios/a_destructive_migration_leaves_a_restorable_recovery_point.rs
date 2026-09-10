#[test]
fn a_destructive_migration_leaves_a_restorable_recovery_point() {
    let dir = tempfile::tempdir().unwrap();
    let database = dir.path().join("runtime.db");
    let mut conn = populated(&database);
    // Leave committed rows in WAL to require their inclusion in the snapshot.
    conn.execute(
        "INSERT INTO migration_test_rows (id, consumed_at)
         VALUES ('in-the-wal', '2026-09-01T00:00:00Z')",
        [],
    )
    .unwrap();

    let list = destructive_list(DROPS_A_TABLE);
    let outcome = apply(&mut conn, &list, Some(&database)).expect("migrate");
    assert_eq!(outcome.applied, [synthetic_destructive_version()]);
    let recovery_point = outcome.recovery_point.expect("a recovery point");

    assert_eq!(mode(&recovery_point), 0o600, "recovery point is owner-only");
    assert_eq!(
        mode(&recovery_directory(&database)),
        0o700,
        "recovery directory is owner-only"
    );

    // Require every dropped live row to remain in the recovery point.
    assert!(
        conn.query_row("SELECT COUNT(*) FROM migration_test_rows", [], |r| {
            r.get::<_, i64>(0)
        })
        .is_err(),
        "the destructive migration did not run"
    );
    let restored = Connection::open(&recovery_point).expect("open recovery point");
    let rows: i64 = restored
        .query_row("SELECT COUNT(*) FROM migration_test_rows", [], |r| r.get(0))
        .expect("recovered table");
    assert_eq!(rows, 65, "the write-ahead log's committed rows are missing");
    let models: i64 = restored
        .query_row("SELECT COUNT(*) FROM models", [], |r| r.get(0))
        .unwrap();
    assert_eq!(models, 1);
}
