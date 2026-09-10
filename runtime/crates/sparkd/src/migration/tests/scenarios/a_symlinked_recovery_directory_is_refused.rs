#[test]
fn a_symlinked_recovery_directory_is_refused() {
    let dir = tempfile::tempdir().unwrap();
    let database = dir.path().join("runtime.db");
    let mut conn = populated(&database);

    let elsewhere = dir.path().join("elsewhere");
    std::fs::create_dir(&elsewhere).unwrap();
    std::os::unix::fs::symlink(&elsewhere, recovery_directory(&database)).unwrap();

    let list = destructive_list(DROPS_A_TABLE);
    let error = apply(&mut conn, &list, Some(&database)).expect_err("must refuse");
    assert!(
        matches!(error, MigrationError::BackupUnavailable { .. }),
        "{error:?}"
    );
    assert!(
        std::fs::read_dir(&elsewhere).unwrap().next().is_none(),
        "the snapshot followed a symlink out of the data directory"
    );
}
