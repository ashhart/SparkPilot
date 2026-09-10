#[test]
fn a_destructive_run_is_idempotent_after_it_succeeds() {
    let dir = tempfile::tempdir().unwrap();
    let database = dir.path().join("runtime.db");
    let mut conn = populated(&database);
    let list = destructive_list(DROPS_A_TABLE);

    let first = apply(&mut conn, &list, Some(&database)).expect("first run");
    assert_eq!(first.applied, [synthetic_destructive_version()]);

    let second = apply(&mut conn, &list, Some(&database)).expect("second run");
    assert!(second.applied.is_empty(), "re-applied a migration");
    assert_eq!(
        second.recovery_point, None,
        "a second run took another recovery point"
    );
}
