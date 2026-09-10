#[test]
fn a_failed_migration_can_be_retried_without_losing_its_recovery_point() {
    let dir = tempfile::tempdir().unwrap();
    let database = dir.path().join("runtime.db");
    let mut conn = populated(&database);
    let directory = recovery_directory(&database);

    // First attempt: the DDL fails after the recovery point is taken.
    let failing =
        destructive_list("DROP TABLE migration_test_rows;\nDROP TABLE table_that_does_not_exist;");
    apply(&mut conn, &failing, Some(&database)).expect_err("first attempt fails");
    let first = directory.join(format!(
        "runtime-before-{}.db",
        synthetic_destructive_version()
    ));
    let first_bytes = std::fs::read(&first).expect("first recovery point");
    assert_eq!(mode(&first), 0o600);

    // Retry with a new recovery filename while preserving the first failed attempt's snapshot.
    apply(&mut conn, &failing, Some(&database)).expect_err("second attempt fails");
    assert_eq!(
        std::fs::read(&first).unwrap(),
        first_bytes,
        "the first recovery point was rewritten"
    );
    let retry = directory.join(format!(
        "runtime-before-{}.retry-1.db",
        synthetic_destructive_version()
    ));
    assert!(retry.exists(), "the retry published no recovery point");
    assert_eq!(mode(&retry), 0o600);

    // Third attempt with DDL that works: the update completes.
    let outcome =
        apply(&mut conn, &destructive_list(DROPS_A_TABLE), Some(&database)).expect("retry");
    assert_eq!(outcome.applied, [synthetic_destructive_version()]);
    assert_eq!(
        outcome.recovery_point.as_deref(),
        Some(
            directory
                .join(format!(
                    "runtime-before-{}.retry-2.db",
                    synthetic_destructive_version()
                ))
                .as_path()
        ),
        "the outcome names a recovery point the retry did not write"
    );
    assert_eq!(
        std::fs::read(&first).unwrap(),
        first_bytes,
        "the first recovery point was rewritten"
    );
}
