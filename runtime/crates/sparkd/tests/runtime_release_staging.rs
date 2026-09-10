use std::os::unix::fs::symlink;

use spark_privd::update::{STAGED_MANIFEST, STAGED_PACKAGE, STAGED_SIGNATURE};
use sparkd::runtime_release::{
    MAX_APP_PACKAGE_BYTES, RuntimeReleaseBundle, RuntimeReleaseStageError, stage_runtime_release,
};

fn bundle(package: Vec<u8>) -> RuntimeReleaseBundle {
    RuntimeReleaseBundle {
        release_id: "dev-0.2.0".into(),
        manifest: b"signed manifest".to_vec(),
        package,
        signature: b"detached signature".to_vec(),
    }
}

#[test]
fn stages_only_the_three_fixed_files_and_replaces_a_previous_release() {
    let temp = tempfile::tempdir().unwrap();
    let root = temp.path().join("updates");
    let first = stage_runtime_release(&root, &bundle(b"first package".to_vec())).unwrap();
    std::fs::write(first.join("untrusted-extra"), b"old").unwrap();

    let second = stage_runtime_release(&root, &bundle(b"second package".to_vec())).unwrap();

    assert_eq!(
        std::fs::read(second.join(STAGED_MANIFEST)).unwrap(),
        b"signed manifest"
    );
    assert_eq!(
        std::fs::read(second.join(STAGED_PACKAGE)).unwrap(),
        b"second package"
    );
    assert_eq!(
        std::fs::read(second.join(STAGED_SIGNATURE)).unwrap(),
        b"detached signature"
    );
    assert!(!second.join("untrusted-extra").exists());
    assert_eq!(std::fs::read_dir(&second).unwrap().count(), 3);
}

#[test]
fn a_symlinked_staging_root_is_rejected_without_touching_its_target() {
    let temp = tempfile::tempdir().unwrap();
    let victim = temp.path().join("victim");
    std::fs::create_dir(&victim).unwrap();
    std::fs::write(victim.join("sentinel"), b"keep").unwrap();
    let root = temp.path().join("updates");
    symlink(&victim, &root).unwrap();

    let error = stage_runtime_release(&root, &bundle(b"package".to_vec())).unwrap_err();

    assert!(matches!(
        error,
        RuntimeReleaseStageError::InvalidStagingRoot
    ));
    assert_eq!(std::fs::read(victim.join("sentinel")).unwrap(), b"keep");
    assert_eq!(std::fs::read_dir(&victim).unwrap().count(), 1);
}

#[test]
fn an_oversized_package_is_refused_before_the_staging_root_exists() {
    let temp = tempfile::tempdir().unwrap();
    let root = temp.path().join("updates");

    let error = stage_runtime_release(
        &root,
        &bundle(vec![0; MAX_APP_PACKAGE_BYTES.saturating_add(1)]),
    )
    .unwrap_err();

    assert!(matches!(
        error,
        RuntimeReleaseStageError::InvalidSize {
            name: "package",
            ..
        }
    ));
    assert!(!root.exists());
}
