#[test]
fn every_additive_migration_only_adds() {
    // The declaration is what the code trusts; this is what checks it.
    for migration in MIGRATIONS {
        if migration.kind != MigrationKind::Additive {
            continue;
        }
        let sql = migration.ddl.to_uppercase();
        for statement in sql.split(';') {
            let statement = statement.trim();
            // Allow UPDATE and DELETE within newly created trigger definitions.
            if statement.starts_with("CREATE TRIGGER") {
                continue;
            }
            for forbidden in ["DROP TABLE", "DROP COLUMN", "DELETE FROM", "RENAME TO"] {
                assert!(
                    !statement.contains(forbidden),
                    "{} is declared additive and contains {forbidden}",
                    migration.version
                );
            }
        }
    }
}
