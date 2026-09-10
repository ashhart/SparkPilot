use super::catalogue::seed_child_if_absent;
use super::*;

fn current_ids() -> (u32, u32) {
    // SAFETY: credential getters return process ids without accessing caller memory.
    unsafe { (libc::getuid(), libc::getgid()) }
}

#[test]
fn catalogue_seed_is_atomic_and_preserves_an_existing_catalogue() {
    let directory = tempfile::tempdir().unwrap();
    let parent = open_trusted_directory(directory.path()).unwrap();
    let (uid, gid) = current_ids();

    assert!(
        seed_child_if_absent(
            &parent,
            "catalogue.json",
            b"signed bootstrap",
            0o640,
            uid,
            gid,
            directory.path(),
        )
        .unwrap()
    );
    assert_eq!(
        std::fs::read(directory.path().join("catalogue.json")).unwrap(),
        b"signed bootstrap"
    );

    assert!(
        !seed_child_if_absent(
            &parent,
            "catalogue.json",
            b"new package bootstrap",
            0o640,
            uid,
            gid,
            directory.path(),
        )
        .unwrap()
    );
    assert_eq!(
        std::fs::read(directory.path().join("catalogue.json")).unwrap(),
        b"signed bootstrap",
        "a package reinstall must not replace a later catalogue snapshot"
    );
    assert!(
        std::fs::read_dir(directory.path())
            .unwrap()
            .all(|entry| !entry
                .unwrap()
                .file_name()
                .to_string_lossy()
                .contains(".seed-")),
        "the successful seed must not leave a temporary file"
    );
}

#[test]
fn catalogue_seed_refuses_a_symlink_without_touching_its_target() {
    let directory = tempfile::tempdir().unwrap();
    let victim = directory.path().join("victim");
    std::fs::write(&victim, b"root-owned content").unwrap();
    std::os::unix::fs::symlink(&victim, directory.path().join("catalogue.json")).unwrap();
    let parent = open_trusted_directory(directory.path()).unwrap();
    let (uid, gid) = current_ids();

    let error = seed_child_if_absent(
        &parent,
        "catalogue.json",
        b"signed bootstrap",
        0o640,
        uid,
        gid,
        directory.path(),
    )
    .unwrap_err();
    assert!(matches!(error, StateError::Symlink { .. }), "got {error:?}");
    assert_eq!(std::fs::read(&victim).unwrap(), b"root-owned content");
}

#[test]
fn bootstrap_reader_rejects_links_and_oversized_input() {
    let directory = tempfile::tempdir().unwrap();
    let source = directory.path().join("bootstrap.json");
    std::fs::write(&source, b"12345").unwrap();
    assert!(matches!(
        read_regular_file(&source, 4),
        Err(StateError::FileTooLarge { .. })
    ));

    let link = directory.path().join("bootstrap-link.json");
    std::os::unix::fs::symlink(&source, &link).unwrap();
    assert!(matches!(
        read_regular_file(&link, 1024),
        Err(StateError::Symlink { .. })
    ));
}
