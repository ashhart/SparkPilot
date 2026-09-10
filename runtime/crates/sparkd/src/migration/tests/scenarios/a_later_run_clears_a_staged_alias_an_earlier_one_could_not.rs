/// Sweep stale staging aliases on ordinary later runs because successful migration versions are never reapplied.
#[test]
fn a_later_run_clears_a_staged_alias_an_earlier_one_could_not() {
    let dir = tempfile::tempdir().unwrap();
    let database = dir.path().join("runtime.db");
    let mut conn = populated(&database);
    let directory = recovery_directory(&database);

    REFUSE_STAGED_CLEANUP.with(|flag| flag.set(true));
    let _ = apply(&mut conn, &destructive_list(DROPS_A_TABLE), Some(&database));
    REFUSE_STAGED_CLEANUP.with(|flag| flag.set(false));
    let staged = directory.join(format!(
        ".runtime-before-{}.staged",
        synthetic_destructive_version()
    ));
    assert!(staged.exists());

    // Leave lookalike filenames and nonregular entries untouched during the sweep.
    let other = directory.join(format!(
        ".other-before-{}.staged",
        synthetic_destructive_version()
    ));
    std::fs::write(&other, b"another database's alias").unwrap();
    let link = directory.join(".runtime-before-symlink.staged");
    std::os::unix::fs::symlink(dir.path().join("elsewhere.db"), &link).unwrap();

    // Even an older build refuses the synthetic future schema only after sweeping its stale aliases.
    assert!(matches!(
        migrate_with_recovery_point(&mut conn, &database),
        Err(MigrationError::UnknownMigration(_))
    ));
    assert!(!staged.exists(), "the stale alias was not cleared");
    assert!(other.exists(), "another database's alias was removed");
    assert!(
        std::fs::symlink_metadata(&link).is_ok(),
        "a symlink was followed and removed"
    );

    assert!(
        directory
            .join(format!(
                "runtime-before-{}.db",
                synthetic_destructive_version()
            ))
            .exists()
    );
}
