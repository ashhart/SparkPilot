#[test]
fn private_remote_migration_preserves_pairing_and_retires_public_routes() {
    for mode in ["cloudflare_public", "private_overlay", "disabled"] {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("runtime.db");
        let mut conn = open(&path).unwrap();
        let boundary = MIGRATIONS.iter().position(|migration| migration.version == "0038").unwrap();
        let prefix = &MIGRATIONS[..boundary];
        assert!(
            apply(&mut conn, prefix, Some(&path))
                .unwrap()
                .recovery_point
                .is_none()
        );
        conn.execute(
            "INSERT INTO remote_access (singleton, enabled, mode, hostname, tunnel_id, access_audience, health, updated_at)
             VALUES (1, 1, ?1, '100.96.4.2', 'obsolete', 'obsolete', 'healthy', '2026-09-05T00:00:00Z')",
            [mode],
        ).unwrap();
        conn.execute("INSERT INTO models (id, recipe_revision, recipe_digest, source_revision, display_name, install_state)
            VALUES ('family/model', 'r1', 'sha256:aa', 's1', 'Family', 'installed')", []).unwrap();
        let outcome = migrate_with_recovery_point(&mut conn, &path).unwrap();
        assert!(outcome.recovery_point.is_some());
        let actual: (i64, String, Option<String>) = conn
            .query_row(
                "SELECT enabled, mode, hostname FROM remote_access",
                [],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
            )
            .unwrap();
        if mode == "private_overlay" {
            assert_eq!(actual, (1, mode.into(), Some("100.96.4.2".into())));
        } else {
            assert_eq!(actual, (0, "disabled".into(), None));
        }
        let obsolete: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM sqlite_master WHERE name = 'consumed_remote_envelopes'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(obsolete, 0);
        assert!(conn.prepare("SELECT tunnel_id FROM remote_access").is_err());
        assert_eq!(
            conn.query_row(
                "SELECT display_name FROM models WHERE id = 'family/model'",
                [],
                |row| row.get::<_, String>(0)
            )
            .unwrap(),
            "Family"
        );
        assert!(
            migrate_with_recovery_point(&mut conn, &path)
                .unwrap()
                .applied
                .is_empty()
        );
    }
}
