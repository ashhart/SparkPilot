use super::*;

include!("tests/scenarios/unknown_migration.rs");

thread_local! {
    static REFUSE_STAGED_CLEANUP: std::cell::Cell<bool> =
        const { std::cell::Cell::new(false) };
}

/// Inject staged-alias cleanup failure after publication because that internal timing cannot be reproduced reliably through filesystem permissions.
pub(super) fn staged_cleanup_is_refused() -> bool {
    REFUSE_STAGED_CLEANUP.with(std::cell::Cell::get)
}

fn mem() -> Connection {
    Connection::open_in_memory().expect("open in-memory")
}

include!("tests/scenarios/sole_owner_rename_and_noop_role_update_preserve_ownership_guards.rs");

include!("tests/scenarios/applies_migrations_and_is_idempotent.rs");

include!("tests/scenarios/pragmas_are_applied_on_open.rs");

include!("tests/scenarios/one_external_container_cannot_be_adopted_by_two_racing_instances.rs");

include!("tests/scenarios/existing_devices_migrate_without_fabricating_a_presence_key.rs");

include!("tests/scenarios/legacy_builds_are_closed_and_artifacts_are_bound_during_0019.rs");

include!(
    "tests/scenarios/version_ten_database_receives_presence_terminals_build_claims_and_fabric_proofs.rs"
);

// Use file-backed tests for recovery behavior beyond in-memory ordering and idempotency.

/// Append a synthetic destructive migration because the shipping migration list is additive.
fn destructive_list(ddl: &'static str) -> Vec<Migration> {
    let mut list: Vec<Migration> = MIGRATIONS.to_vec();
    list.push(Migration {
        version: synthetic_destructive_version(),
        name: "synthetic_destructive",
        kind: MigrationKind::Destructive,
        ddl,
    });
    list
}

/// Choose a synthetic destructive version after every shipping migration to avoid future version collisions.
fn synthetic_destructive_version() -> &'static str {
    static VERSION: std::sync::OnceLock<String> = std::sync::OnceLock::new();
    VERSION
        .get_or_init(|| {
            format!(
                "{:04}",
                MIGRATIONS.last().unwrap().version.parse::<u64>().unwrap() + 1
            )
        })
        .as_str()
}

const DROPS_A_TABLE: &str = "DROP TABLE migration_test_rows;";

fn populated(path: &std::path::Path) -> Connection {
    let mut conn = open(path).expect("open");
    let baseline = migrate_with_recovery_point(&mut conn, path).expect("baseline schema");
    // The fixture starts empty; remove its pre-seed recovery point so each recovery-failure test owns its setup.
    if let Some(recovery) = baseline.recovery_point {
        std::fs::remove_file(recovery).unwrap();
        std::fs::remove_dir(recovery_directory(path)).unwrap();
    }
    conn.execute_batch("CREATE TABLE migration_test_rows (id TEXT, consumed_at TEXT)")
        .unwrap();
    conn.execute(
        "INSERT INTO models (id, recipe_revision, recipe_digest, source_revision, display_name, install_state)
         VALUES ('example/model', 'r1', 'sha256:aa', 's1', 'Example', 'installed')",
        [],
    )
    .unwrap();
    for index in 0..64 {
        conn.execute(
            "INSERT INTO migration_test_rows (id, consumed_at)
             VALUES (?1, '2026-09-01T00:00:00Z')",
            rusqlite::params![format!("sha256-{index}")],
        )
        .unwrap();
    }
    conn
}

fn mode(path: &std::path::Path) -> u32 {
    std::fs::symlink_metadata(path)
        .unwrap()
        .permissions()
        .mode()
        & 0o777
}

include!("tests/scenarios/a_destructive_migration_leaves_a_restorable_recovery_point.rs");

include!("tests/scenarios/a_failing_destructive_migration_rolls_back_and_changes_nothing.rs");

include!("tests/scenarios/no_schema_or_data_changes_when_the_recovery_point_cannot_be_written.rs");

include!("tests/scenarios/a_failed_migration_can_be_retried_without_losing_its_recovery_point.rs");

include!(
    "tests/scenarios/a_published_recovery_point_survives_a_staged_alias_that_cannot_be_removed.rs"
);

include!("tests/scenarios/a_later_run_clears_a_staged_alias_an_earlier_one_could_not.rs");

include!("tests/scenarios/a_database_path_that_is_not_the_open_file_is_refused.rs");

include!("tests/scenarios/a_symlinked_recovery_directory_is_refused.rs");

include!(
    "tests/scenarios/a_file_backed_caller_cannot_reach_a_destructive_migration_without_a_backup.rs"
);

include!("tests/scenarios/an_additive_only_run_writes_no_recovery_point.rs");

include!("tests/scenarios/a_destructive_run_is_idempotent_after_it_succeeds.rs");

include!("tests/scenarios/every_additive_migration_only_adds.rs");

/// BH-32: the renumbered guest migration recorded version 30 with no name at all.
#[test]
fn bh_32_a_database_that_recorded_the_renumbered_guest_migration_is_refused_by_name() {
    let mut conn = mem();
    let head = MIGRATIONS
        .iter()
        .copied()
        .take_while(|migration| migration.version < "0030")
        .collect::<Vec<_>>();
    apply(&mut conn, &head, None).expect("everything before the renumber applies");
    let guest = MIGRATIONS
        .iter()
        .find(|migration| migration.name == "0031_guest_shared_access")
        .expect("the guest migration ships");
    conn.execute_batch(guest.ddl).expect("the old 0030 applied");
    conn.execute(
        "INSERT INTO schema_migrations (version, applied_at) VALUES (30, 'then')",
        [],
    )
    .expect("record the version the old branch recorded");

    let error = migrate(&mut conn).expect_err("a renumbered migration must be refused");
    assert!(
        matches!(error, MigrationError::VersionMismatch { .. }),
        "expected a named refusal, got {error}"
    );
    let message = error.to_string();
    assert!(message.contains("0030_automations"), "{message}");
    assert!(message.contains("automations"), "{message}");
}

/// A database written before names were recorded, but otherwise complete, keeps working and gains its names.
#[test]
fn bh_32_an_unnamed_but_complete_database_is_accepted_and_named() {
    let mut conn = mem();
    migrate(&mut conn).expect("first apply");
    conn.execute("UPDATE schema_migrations SET name = NULL", [])
        .expect("forget every name");
    assert!(migrate(&mut conn).expect("second apply").is_empty());
    let unnamed: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM schema_migrations WHERE name IS NULL",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(unnamed, 0, "every recorded version is named again");
}

/// A migration that never ran cannot be slipped in underneath one that did.
#[test]
fn bh_32_a_migration_below_the_recorded_high_water_mark_is_refused() {
    let mut conn = mem();
    migrate(&mut conn).expect("everything applies");
    conn.execute("DELETE FROM schema_migrations WHERE version = 30", [])
        .expect("forget one migration in the middle");

    let error = migrate(&mut conn).expect_err("a hole must be refused");
    assert!(
        matches!(error, MigrationError::SkippedMigration { .. }),
        "expected a named refusal, got {error}"
    );
}

/// Versions may skip while parallel branches are open, but they may never go backwards.
#[test]
fn bh_32_a_gap_in_the_shipped_list_applies_and_a_repeat_does_not() {
    let mut conn = mem();
    let mut list = MIGRATIONS
        .iter()
        .copied()
        .take_while(|migration| migration.version < "0030")
        .collect::<Vec<_>>();
    let mut gapped = MIGRATIONS[29];
    gapped.version = "0035";
    list.push(gapped);
    assert_eq!(
        apply(&mut conn, &list, None)
            .expect("gaps apply")
            .applied
            .len(),
        list.len()
    );
    assert!(
        apply(&mut conn, &list, None)
            .expect("idempotent")
            .applied
            .is_empty()
    );

    let mut backwards = list.clone();
    backwards.push(MIGRATIONS[29]);
    assert!(matches!(
        apply(&mut conn, &backwards, None),
        Err(MigrationError::OutOfOrder(_, _))
    ));
}

include!("tests/scenarios/private_remote_migration_preserves_pairing_and_retires_public_routes.rs");
include!("tests/scenarios/family_preview_upgrade.rs");
