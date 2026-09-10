#[test]
fn a_file_backed_caller_cannot_reach_a_destructive_migration_without_a_backup() {
    let dir = tempfile::tempdir().unwrap();
    let database = dir.path().join("runtime.db");
    let mut conn = populated(&database);

    let list = destructive_list(DROPS_A_TABLE);
    let error = apply(&mut conn, &list, None).expect_err("must refuse");
    assert!(
        matches!(&error, MigrationError::RecoveryPointRequired(version) if version == synthetic_destructive_version()),
        "{error:?}"
    );
    let rows: i64 = conn
        .query_row("SELECT COUNT(*) FROM migration_test_rows", [], |r| r.get(0))
        .expect("no DDL ran");
    assert_eq!(rows, 64);

    // In-memory stays simple: there is no file to protect.
    let mut memory = mem();
    memory
        .execute_batch("CREATE TABLE migration_test_rows (id TEXT)")
        .unwrap();
    apply(&mut memory, &list, None).expect("in-memory needs no recovery point");
}
