#[test]
fn pragmas_are_applied_on_open() {
    let dir = std::env::temp_dir().join(format!("sparkd-migration-test-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("runtime.db");
    let mut conn = open(&path).expect("open applies pragmas without error");
    migrate_with_recovery_point(&mut conn, &path).expect("migrate");
    let wal: String = conn
        .query_row("PRAGMA journal_mode", [], |r| r.get(0))
        .unwrap();
    assert_eq!(wal.to_uppercase(), "WAL");
    std::fs::remove_dir_all(&dir).ok();
}
