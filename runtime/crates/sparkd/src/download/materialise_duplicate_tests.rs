use super::*;

const REVISION: &str = "cc84af2fe71647d87f4486c064f320e1e7535243";

#[test]
fn a_truncated_existing_blob_is_repaired_before_snapshot_publication() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().join("models");
    let staged = dir.path().join("verified.bin");
    std::fs::write(&staged, b"complete verified weights").unwrap();
    let blob = crate::model_paths::blob_path(&root, &sha256_file(&staged).unwrap()).unwrap();
    std::fs::create_dir_all(blob.parent().unwrap()).unwrap();
    std::fs::write(&blob, b"truncated").unwrap();
    materialise_snapshot(
        &[("weights.bin".into(), staged)],
        &root,
        "example/model",
        REVISION,
    )
    .unwrap();
    let snapshot = crate::model_paths::snapshot_path(&root, "example/model", REVISION).unwrap();
    assert_eq!(
        std::fs::read(snapshot.join("weights.bin")).unwrap(),
        b"complete verified weights"
    );
    assert_eq!(std::fs::read(blob).unwrap(), b"complete verified weights");
}

#[cfg(unix)]
#[test]
fn a_symlinked_blob_is_never_used_as_verified_weights() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().join("models");
    let staged = dir.path().join("verified.bin");
    let outside = dir.path().join("outside.bin");
    std::fs::write(&staged, b"verified weights").unwrap();
    std::fs::write(&outside, b"other private data").unwrap();
    let blob = crate::model_paths::blob_path(&root, &sha256_file(&staged).unwrap()).unwrap();
    std::fs::create_dir_all(blob.parent().unwrap()).unwrap();
    std::os::unix::fs::symlink(&outside, &blob).unwrap();
    assert!(
        materialise_snapshot(
            &[("weights.bin".into(), staged)],
            &root,
            "example/model",
            REVISION
        )
        .is_err()
    );
    assert_eq!(std::fs::read(outside).unwrap(), b"other private data");
}

/// Remove redundant staged copies after snapshot creation while retaining hardlinks for reuse.
#[test]
fn a_copied_staged_file_is_removed_and_a_linked_one_is_kept() {
    let dir = tempfile::tempdir().unwrap();
    let models_root = dir.path().join("models");
    let work = dir.path().join("downloads");
    std::fs::create_dir_all(&work).unwrap();

    // `kept.bin` is new: it is hard-linked into the store and stays.
    let kept = work.join("kept.bin");
    std::fs::write(&kept, b"kept bytes").unwrap();
    // Simulate a copied duplicate with a separate inode from the existing blob.
    let copied = work.join("copied.bin");
    std::fs::write(&copied, b"copied bytes").unwrap();
    let existing_blob =
        crate::model_paths::blob_path(&models_root, &sha256_file(&copied).unwrap()).unwrap();
    std::fs::create_dir_all(existing_blob.parent().unwrap()).unwrap();
    std::fs::copy(&copied, &existing_blob).unwrap();

    materialise_snapshot(
        &[
            ("kept.bin".into(), kept.clone()),
            ("copied.bin".into(), copied.clone()),
        ],
        &models_root,
        "example/model",
        REVISION,
    )
    .unwrap();

    assert!(kept.exists(), "a linked staged file is kept for reuse");
    assert!(
        !copied.exists(),
        "a staged file the store already holds as another inode is removed"
    );
    let snapshot =
        crate::model_paths::snapshot_path(&models_root, "example/model", REVISION).unwrap();
    assert_eq!(
        std::fs::read(snapshot.join("kept.bin")).unwrap(),
        b"kept bytes"
    );
    assert_eq!(
        std::fs::read(snapshot.join("copied.bin")).unwrap(),
        b"copied bytes"
    );
    assert_eq!(std::fs::read(&existing_blob).unwrap(), b"copied bytes");
}
