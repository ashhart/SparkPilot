#[test]
fn no_schema_or_data_changes_when_the_recovery_point_cannot_be_written() {
    let dir = tempfile::tempdir().unwrap();
    let database = dir.path().join("runtime.db");
    let mut conn = populated(&database);

    // Reject a regular file occupying the required recovery-directory path.
    std::fs::write(recovery_directory(&database), b"not a directory").unwrap();

    let list = destructive_list(DROPS_A_TABLE);
    let error = apply(&mut conn, &list, Some(&database)).expect_err("must refuse");
    assert!(
        matches!(error, MigrationError::BackupUnavailable { .. }),
        "{error:?}"
    );

    let rows: i64 = conn
        .query_row("SELECT COUNT(*) FROM migration_test_rows", [], |r| r.get(0))
        .expect("no DDL ran");
    assert_eq!(rows, 64);
    let version: i64 = conn
        .query_row("SELECT MAX(version) FROM schema_migrations", [], |r| {
            r.get(0)
        })
        .unwrap();
    assert_eq!(
        version,
        MIGRATIONS.last().unwrap().version.parse::<i64>().unwrap()
    );
}
