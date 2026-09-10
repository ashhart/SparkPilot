#[test]
fn an_additive_only_run_writes_no_recovery_point() {
    let dir = tempfile::tempdir().unwrap();
    let database = dir.path().join("runtime.db");
    let mut conn = open(&database).expect("open");

    let additive_count = MIGRATIONS.iter().position(|migration| migration.kind == MigrationKind::Destructive).unwrap_or(MIGRATIONS.len());
    let outcome = apply(
        &mut conn,
        &MIGRATIONS[..additive_count],
        Some(&database),
    )
    .expect("additive migrations");
    assert_eq!(outcome.applied.len(), additive_count);
    assert_eq!(outcome.recovery_point, None);
    assert!(
        !recovery_directory(&database).exists(),
        "an additive run created a recovery directory"
    );

    let again = apply(
        &mut conn,
        &MIGRATIONS[..additive_count],
        Some(&database),
    )
    .expect("second run");
    assert!(again.applied.is_empty());
    assert_eq!(again.recovery_point, None);
}
