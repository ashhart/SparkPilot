#[test]
fn a_failing_destructive_migration_rolls_back_and_changes_nothing() {
    let dir = tempfile::tempdir().unwrap();
    let database = dir.path().join("runtime.db");
    let mut conn = populated(&database);

    // Fail after valid DDL to verify schema changes and version recording roll back together.
    let list =
        destructive_list("DROP TABLE migration_test_rows;\nDROP TABLE table_that_does_not_exist;");
    let error = apply(&mut conn, &list, Some(&database)).expect_err("must fail");
    assert!(matches!(error, MigrationError::Sqlite(_)), "{error:?}");

    let rows: i64 = conn
        .query_row("SELECT COUNT(*) FROM migration_test_rows", [], |r| r.get(0))
        .expect("the table survived the rolled-back transaction");
    assert_eq!(rows, 64);
    let version: i64 = conn
        .query_row("SELECT MAX(version) FROM schema_migrations", [], |r| {
            r.get(0)
        })
        .unwrap();
    assert_eq!(
        version,
        MIGRATIONS.last().unwrap().version.parse::<i64>().unwrap(),
        "a failed migration recorded its version"
    );
    // The recovery point was taken before the attempt and is kept.
    assert!(
        recovery_directory(&database)
            .join(format!(
                "runtime-before-{}.db",
                synthetic_destructive_version()
            ))
            .exists()
    );
}
