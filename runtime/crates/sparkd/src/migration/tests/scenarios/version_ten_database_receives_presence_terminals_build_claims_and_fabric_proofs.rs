#[test]
fn version_ten_database_receives_presence_terminals_build_claims_and_fabric_proofs() {
    let mut conn = mem();
    for migration in MIGRATIONS
        .iter()
        .take_while(|entry| entry.version != "0011")
    {
        conn.execute_batch(migration.ddl).unwrap();
        conn.execute(
            "INSERT OR IGNORE INTO schema_migrations (version, applied_at)
             VALUES (?1, '2026-08-29T00:00:00Z')",
            rusqlite::params![migration.version.parse::<i64>().unwrap()],
        )
        .unwrap();
    }

    let applied = migrate(&mut conn).unwrap();
    assert_eq!(
        applied,
        MIGRATIONS
            .iter()
            .filter(|entry| entry.version >= "0011")
            .map(|entry| entry.version)
            .collect::<Vec<_>>()
    );

    let terminal_table: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM sqlite_master
             WHERE type = 'table' AND name = 'project_terminals'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(terminal_table, 1);

    let presence_table: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM sqlite_master
             WHERE type = 'table' AND name = 'presence_challenges'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(presence_table, 1);

    let fabric_proof_table: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM sqlite_master
             WHERE type = 'table' AND name = 'fabric_peer_proofs'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(fabric_proof_table, 1);

    let build_columns: Vec<String> = conn
        .prepare("PRAGMA table_info(builds)")
        .unwrap()
        .query_map([], |row| row.get(1))
        .unwrap()
        .collect::<rusqlite::Result<_>>()
        .unwrap();
    assert!(build_columns.iter().any(|name| name == "claim_token_hash"));
    assert!(build_columns.iter().any(|name| name == "claim_expires_at"));
    assert!(build_columns.iter().any(|name| name == "source_sha256"));
    assert!(build_columns.iter().any(|name| name == "recipe_sha256"));
}
