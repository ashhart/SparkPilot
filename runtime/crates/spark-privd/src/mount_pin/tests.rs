use super::*;
use std::fs;

fn fixture() -> (tempfile::TempDir, PathBuf, PathBuf) {
    let root = tempfile::tempdir().unwrap();
    let snapshots = root.path().join("models");
    let leaf = snapshots.join("snapshots/example/model/rev");
    fs::create_dir_all(&leaf).unwrap();
    (root, snapshots, leaf)
}

#[test]
fn an_unchanged_directory_verifies_against_its_pin() {
    let (_root, snapshots, leaf) = fixture();
    let pin = PinnedDirectory::open(&snapshots, Path::new("snapshots/example/model/rev")).unwrap();
    assert_eq!(pin.path(), leaf);
    pin.verify().unwrap();
}

/// The swap the race depends on: rename the validated directory away and put a link to somewhere else in its place.
#[test]
fn a_directory_swapped_for_a_symlink_after_validation_no_longer_verifies() {
    let (root, snapshots, leaf) = fixture();
    let pin = PinnedDirectory::open(&snapshots, Path::new("snapshots/example/model/rev")).unwrap();
    let elsewhere = root.path().join("elsewhere");
    fs::create_dir_all(&elsewhere).unwrap();
    fs::rename(&leaf, root.path().join("moved")).unwrap();
    std::os::unix::fs::symlink(&elsewhere, &leaf).unwrap();

    let error = pin.verify().unwrap_err();
    assert!(matches!(error, PinError::Symlink(_)), "{error}");
}

/// A swap for a different real directory is a different inode, so the pin still refuses it.
#[test]
fn a_directory_swapped_for_another_directory_no_longer_verifies() {
    let (root, snapshots, leaf) = fixture();
    let pin = PinnedDirectory::open(&snapshots, Path::new("snapshots/example/model/rev")).unwrap();
    fs::rename(&leaf, root.path().join("moved")).unwrap();
    fs::create_dir_all(&leaf).unwrap();

    let error = pin.verify().unwrap_err();
    assert!(matches!(error, PinError::Replaced(_)), "{error}");
}

#[test]
fn a_link_in_any_component_is_refused_at_validation() {
    let (root, snapshots, _leaf) = fixture();
    let elsewhere = root.path().join("elsewhere/model/rev");
    fs::create_dir_all(&elsewhere).unwrap();
    std::os::unix::fs::symlink(
        root.path().join("elsewhere"),
        snapshots.join("snapshots/linked"),
    )
    .unwrap();

    let error =
        PinnedDirectory::open(&snapshots, Path::new("snapshots/linked/model/rev")).unwrap_err();
    assert!(matches!(error, PinError::Symlink(_)), "{error}");
}

#[test]
fn a_root_that_is_itself_a_link_is_refused() {
    let (root, snapshots, _leaf) = fixture();
    let linked_root = root.path().join("models-link");
    std::os::unix::fs::symlink(&snapshots, &linked_root).unwrap();

    let error =
        PinnedDirectory::open(&linked_root, Path::new("snapshots/example/model/rev")).unwrap_err();
    assert!(matches!(error, PinError::Symlink(_)), "{error}");
}

#[test]
fn traversal_absolute_and_empty_relative_paths_are_refused_before_any_syscall() {
    let (_root, snapshots, _leaf) = fixture();
    for relative in [
        "",
        "/etc",
        "../models",
        "snapshots/../snapshots",
        "./snapshots",
    ] {
        let error = PinnedDirectory::open(&snapshots, Path::new(relative)).unwrap_err();
        assert!(
            matches!(error, PinError::UnsafePath(_)),
            "{relative}: {error}"
        );
    }
    let error = PinnedDirectory::open(Path::new("relative"), Path::new("x")).unwrap_err();
    assert!(matches!(error, PinError::UnsafePath(_)), "{error}");
}

#[test]
fn a_regular_file_is_not_a_mountable_directory() {
    let (_root, snapshots, leaf) = fixture();
    fs::write(leaf.join("weights.bin"), b"x").unwrap();
    let error = PinnedDirectory::open(
        &snapshots,
        Path::new("snapshots/example/model/rev/weights.bin"),
    )
    .unwrap_err();
    assert!(matches!(error, PinError::Io(_, _)), "{error}");
}
