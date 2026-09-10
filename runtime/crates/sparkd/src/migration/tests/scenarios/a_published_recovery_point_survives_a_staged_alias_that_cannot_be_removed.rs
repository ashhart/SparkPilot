#[test]
fn a_published_recovery_point_survives_a_staged_alias_that_cannot_be_removed() {
    let dir = tempfile::tempdir().unwrap();
    let database = dir.path().join("runtime.db");
    let mut conn = populated(&database);

    REFUSE_STAGED_CLEANUP.with(|flag| flag.set(true));
    let outcome = apply(&mut conn, &destructive_list(DROPS_A_TABLE), Some(&database));
    REFUSE_STAGED_CLEANUP.with(|flag| flag.set(false));

    let outcome = outcome.expect("a staged alias that will not unlink is not a failure");
    assert_eq!(
        outcome.applied,
        [synthetic_destructive_version()],
        "the DDL did not run"
    );
    let recovery_point = outcome.recovery_point.expect("a recovery point");
    assert_eq!(mode(&recovery_point), 0o600);

    // Cleanup failure cannot invalidate an already durable complete recovery point.
    let restored = Connection::open(&recovery_point).expect("open recovery point");
    let rows: i64 = restored
        .query_row("SELECT COUNT(*) FROM migration_test_rows", [], |r| r.get(0))
        .expect("recovered table");
    assert_eq!(rows, 64);
    assert!(
        recovery_directory(&database)
            .join(format!(
                ".runtime-before-{}.staged",
                synthetic_destructive_version()
            ))
            .exists(),
        "the seam did not refuse the unlink"
    );
}
