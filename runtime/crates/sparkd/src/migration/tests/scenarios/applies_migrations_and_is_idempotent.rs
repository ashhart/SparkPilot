#[test]
fn applies_migrations_and_is_idempotent() {
    let mut conn = mem();
    let applied = migrate(&mut conn).expect("first apply");
    assert_eq!(applied.len(), MIGRATIONS.len());

    let again = migrate(&mut conn).expect("second apply");
    assert!(again.is_empty(), "idempotent second run applies nothing");

    let count: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM sqlite_master WHERE type='table'",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert!(
        count >= 26,
        "bootstrap schema materialised, got {count} tables"
    );
}

#[test]
fn qa6_database_adds_development_without_replacing_retention_indexes() {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("qa6.db");
    let mut conn = open(&path).unwrap();
    let boundary = MIGRATIONS.iter().position(|m| m.version == "0040").unwrap();
    apply(&mut conn, &MIGRATIONS[..boundary], Some(&path)).unwrap();
    conn.execute("INSERT INTO devices(id,display_name,platform,public_key_spki,public_key_fingerprint,role,paired_at)
        VALUES('owner','Owner','ios',X'010203','owner-key','owner','created')", []).unwrap();
    let outcome = migrate_with_recovery_point(&mut conn, &path).unwrap();
    assert_eq!(outcome.applied, vec!["0040", "0041"]);
    assert!(outcome.recovery_point.is_none());
    for name in ["pairing_challenges_expiry_idx", "idempotency_records_expiry_idx", "development_workspaces", "model_idle_timeouts"] {
        let count: i64 = conn.query_row("SELECT COUNT(*) FROM sqlite_master WHERE name=?1", [name], |r| r.get(0)).unwrap();
        assert_eq!(count, 1, "missing schema object {name}");
    }
    let key: Vec<u8> = conn.query_row("SELECT public_key_spki FROM devices WHERE id='owner'", [], |r| r.get(0)).unwrap();
    assert_eq!(key, vec![1, 2, 3]);
    assert!(migrate(&mut conn).unwrap().is_empty());
}
