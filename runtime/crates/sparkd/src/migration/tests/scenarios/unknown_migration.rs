#[test]
fn an_unknown_recorded_migration_refuses_to_open_without_relabelling_history() {
    let mut conn = mem();
    migrate(&mut conn).unwrap();
    conn.execute_batch("UPDATE schema_migrations SET name = NULL;
        INSERT INTO schema_migrations(version, name, applied_at) VALUES (9999, '9999_future', '2026-09-05');").unwrap();
    assert!(
        migrate(&mut conn).is_err(),
        "an older build accepted a future database"
    );
    let relabelled: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM schema_migrations WHERE version <> 9999 AND name IS NOT NULL",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(
        relabelled, 0,
        "failed preflight rewrote migration provenance"
    );
}
