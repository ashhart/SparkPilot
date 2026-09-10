#[test]
fn a_database_path_that_is_not_the_open_file_is_refused() {
    let dir = tempfile::tempdir().unwrap();
    let database = dir.path().join("runtime.db");
    let other = dir.path().join("second.db");
    let mut conn = populated(&database);
    let _ = populated(&other);

    let error = migrate_with_recovery_point(&mut conn, &other).expect_err("must refuse");
    assert!(
        matches!(error, MigrationError::DatabaseMismatch { .. }),
        "{error:?}"
    );
    assert!(
        !recovery_directory(&other).exists(),
        "a snapshot of one database was staged under another's name"
    );

    // In-memory has no file to name, so it cannot use this entry point.
    let mut memory = mem();
    assert!(matches!(
        migrate_with_recovery_point(&mut memory, &database).expect_err("must refuse"),
        MigrationError::DatabaseMismatch { .. }
    ));

    // The same file by a different spelling is the same file.
    let spelled = dir.path().join(".").join("runtime.db");
    migrate_with_recovery_point(&mut conn, &spelled).expect("same file, different path");
}
