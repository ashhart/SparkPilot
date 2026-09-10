fn family_preview(conn: &mut Connection, retired: bool) {
    apply(conn, &MIGRATIONS[..32], None).unwrap();
    conn.execute_batch(include_str!("../../../../migrations/0037_household.sql"))
        .unwrap();
    conn.execute(
        "INSERT INTO schema_migrations(version, applied_at) VALUES(33, 'household-created')",
        [],
    )
    .unwrap();
    if retired {
        conn.execute_batch(include_str!(
            "../../../../migrations/0038_private_remote_only.sql"
        ))
        .unwrap();
        conn.execute(
            "INSERT INTO schema_migrations(version, applied_at) VALUES(34, 'private-retired')",
            [],
        )
        .unwrap();
    }
    conn.execute("UPDATE schema_migrations SET name = NULL", [])
        .unwrap();
    conn.execute("INSERT INTO devices(id,display_name,platform,public_key_spki,public_key_fingerprint,role,paired_at)
        VALUES('owner','Granddad','ios',X'010203','owner-key','owner','created')", []).unwrap();
    conn.execute("INSERT INTO household_notes(id,title,body,revision,author_device_id,author_name,updated_by_name,created_at,updated_at)
        VALUES('family-note','Shopping','Milk',2,'owner','Granddad','Granddad','created','updated')", []).unwrap();
}

#[test]
fn family_preview_upgrade_preserves_notes_and_records_both_histories() {
    for retired in [false, true] {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("family.db");
        let mut conn = open(&path).unwrap();
        family_preview(&mut conn, retired);
        let outcome = migrate_with_recovery_point(&mut conn, &path).unwrap();
        let snapshot = Connection::open(outcome.recovery_point.as_ref().unwrap()).unwrap();
        assert_eq!(
            snapshot
                .query_row("SELECT MAX(version) FROM schema_migrations", [], |r| r
                    .get::<_, i64>(0))
                .unwrap(),
            if retired { 34 } else { 33 }
        );
        assert_eq!(
            conn.query_row(
                "SELECT body FROM household_notes WHERE id='family-note'",
                [],
                |r| r.get::<_, String>(0)
            )
            .unwrap(),
            "Milk"
        );
        assert_eq!(
            conn.query_row("SELECT MAX(version) FROM schema_migrations", [], |r| r
                .get::<_, i64>(0))
                .unwrap(),
            MIGRATIONS.last().unwrap().version.parse::<i64>().unwrap()
        );
        assert_eq!(
            conn.query_row(
                "SELECT public_key_spki FROM devices WHERE id='owner'",
                [],
                |r| r.get::<_, Vec<u8>>(0)
            )
            .unwrap(),
            vec![1, 2, 3]
        );
        assert_eq!(
            conn.query_row("SELECT COUNT(*) FROM pragma_foreign_key_check", [], |r| r
                .get::<_, i64>(
                0
            ))
            .unwrap(),
            0
        );
        assert!(conn.prepare("SELECT lease_fence FROM operations").is_ok());
        assert!(
            conn.prepare("SELECT made_at FROM web_call_reservations")
                .is_ok()
        );
        assert!(
            migrate_with_recovery_point(&mut conn, &path)
                .unwrap()
                .applied
                .is_empty()
        );
    }
}

#[test]
fn an_unrecognised_preview_schema_is_never_relabelled() {
    let mut conn = mem();
    family_preview(&mut conn, true);
    conn.execute_batch("ALTER TABLE household_notes ADD COLUMN unexplained TEXT;")
        .unwrap();
    assert!(matches!(
        migrate(&mut conn),
        Err(MigrationError::VersionMismatch { .. })
    ));
    assert_eq!(
        conn.query_row("SELECT MAX(version) FROM schema_migrations", [], |r| r
            .get::<_, i64>(0))
            .unwrap(),
        34
    );
    assert!(
        conn.prepare("SELECT made_at FROM web_call_reservations")
            .is_err()
    );
}

#[test]
fn preview_history_is_not_changed_without_a_file_recovery_point() {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("family.db");
    let mut conn = open(&path).unwrap();
    family_preview(&mut conn, true);
    assert!(matches!(
        migrate(&mut conn),
        Err(MigrationError::RecoveryPointRequired(_))
    ));
    assert_eq!(
        conn.query_row("SELECT MAX(version) FROM schema_migrations", [], |r| r
            .get::<_, i64>(0))
            .unwrap(),
        34
    );
}
