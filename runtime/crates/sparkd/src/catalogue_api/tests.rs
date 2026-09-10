use super::*;
use std::os::unix::fs::symlink;

#[test]
fn safe_read_never_follows_a_catalogue_symlink() {
    let directory = tempfile::tempdir().unwrap();
    let victim = directory.path().join("victim.json");
    let catalogue = directory.path().join("catalogue.json");
    fs::write(&victim, b"secret").unwrap();
    symlink(&victim, &catalogue).unwrap();

    let error = safe_read(&catalogue, MAX_CATALOGUE_BYTES).unwrap_err();
    assert_eq!(error.code(), "CATALOGUE_ENTRY_UNSAFE");
    assert_eq!(fs::read(&victim).unwrap(), b"secret");
}

#[test]
fn restart_recovery_restores_only_a_regular_previous_snapshot() {
    let directory = tempfile::tempdir().unwrap();
    let catalogue = directory.path().join("catalogue.json");
    let previous = previous_path(&catalogue);
    fs::write(&previous, b"verified-old-snapshot").unwrap();

    assert!(recover_interrupted_promotion(&catalogue).unwrap());
    assert_eq!(fs::read(&catalogue).unwrap(), b"verified-old-snapshot");
    assert!(!recover_interrupted_promotion(&catalogue).unwrap());

    fs::remove_file(&catalogue).unwrap();
    let victim = directory.path().join("victim.json");
    fs::write(&victim, b"do-not-follow").unwrap();
    symlink(&victim, &previous).unwrap();
    assert!(matches!(
        recover_interrupted_promotion(&catalogue),
        Err(CatalogueRefreshError::NonRegular(_))
    ));
    assert_eq!(fs::read(&victim).unwrap(), b"do-not-follow");
}

#[test]
fn restart_staging_reuses_exact_bytes_replaces_partial_and_refuses_symlinks() {
    let directory = tempfile::tempdir().unwrap();
    let staged = directory.path().join(".catalogue.candidate-operation");
    fs::write(&staged, b"partial").unwrap();
    stage_candidate(&staged, b"complete-candidate").unwrap();
    assert_eq!(fs::read(&staged).unwrap(), b"complete-candidate");
    stage_candidate(&staged, b"complete-candidate").unwrap();

    fs::remove_file(&staged).unwrap();
    let victim = directory.path().join("victim");
    fs::write(&victim, b"leave-me").unwrap();
    symlink(&victim, &staged).unwrap();
    assert!(matches!(
        stage_candidate(&staged, b"candidate"),
        Err(CatalogueRefreshError::NonRegular(_))
    ));
    assert_eq!(fs::read(&victim).unwrap(), b"leave-me");
}
