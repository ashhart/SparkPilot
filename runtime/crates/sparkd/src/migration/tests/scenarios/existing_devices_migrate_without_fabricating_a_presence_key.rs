#[test]
fn existing_devices_migrate_without_fabricating_a_presence_key() {
    let mut conn = mem();
    for migration in MIGRATIONS
        .iter()
        .take_while(|entry| entry.version != "0007")
    {
        conn.execute_batch(migration.ddl).unwrap();
        conn.execute(
            "INSERT OR IGNORE INTO schema_migrations (version, applied_at)
             VALUES (?1, '2026-08-28T14:00:00Z')",
            rusqlite::params![migration.version.parse::<i64>().unwrap()],
        )
        .unwrap();
    }
    conn.execute(
        "INSERT INTO devices
            (id, display_name, platform, public_key_spki, public_key_fingerprint,
             role, paired_at, metadata_json)
         VALUES (?1, 'Existing iPhone', 'ios', X'010203', 'existing',
                 'owner', '2026-08-28T14:00:00Z', '{}')",
        rusqlite::params![uuid::Uuid::new_v4().to_string()],
    )
    .unwrap();

    let applied = migrate(&mut conn).unwrap();
    assert_eq!(applied.first().map(String::as_str), Some("0007"));
    assert_eq!(
        applied.last().map(String::as_str),
        MIGRATIONS.last().map(|entry| entry.version)
    );
    let keys: (Option<Vec<u8>>, Option<String>) = conn
        .query_row(
            "SELECT presence_public_key_spki, presence_public_key_fingerprint FROM devices",
            [],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .unwrap();
    assert_eq!(keys, (None, None));
}
