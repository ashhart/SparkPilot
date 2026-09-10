/// The race the helper must lose safely: the service swaps the validated directory for a link while docker is mounting it.
#[test]
fn a_snapshot_swapped_for_a_symlink_during_launch_is_torn_down() {
    let root = tempfile::tempdir().unwrap();
    let snapshot = root.path().join("models/snapshots/example/model-32b/rev");
    let elsewhere = root.path().join("root-only-secrets");
    fs::create_dir_all(&elsewhere).unwrap();
    // The fake docker performs the swap inside `run`, after the helper validated and pinned the directory.
    let swap = format!(
        "  mv '{snapshot}' '{moved}' && ln -s '{elsewhere}' '{snapshot}'\n  printf '%s\\n' container-id",
        snapshot = snapshot.display(),
        moved = root.path().join("moved-away").display(),
        elsewhere = elsewhere.display(),
    );
    let (docker, log) = gpu_driver_fake_docker(root.path(), &swap);
    let backend = gpu_driver_backend(
        root.path(),
        &docker,
        &root.path().join("missing-module-version"),
        &root.path().join("missing-lib"),
    );
    let operation = gpu_driver_start_operation(root.path());
    let instance_id = match &operation {
        PrivilegedOperation::StartModel { instance_id, .. } => *instance_id,
        _ => unreachable!(),
    };

    let error = backend
        .execute(&operation)
        .expect_err("a swapped mount source is refused");

    assert!(
        matches!(&error, BackendError::Failure(message) if message.contains("replaced during launch")),
        "{error}"
    );
    let calls = fs::read_to_string(&log).unwrap();
    let lines: Vec<&str> = calls.lines().collect();
    let run = lines
        .iter()
        .position(|line| line.starts_with("run "))
        .expect("docker run was attempted");
    assert!(
        lines[run].contains(&format!("--volume={}:/model:ro", snapshot.display())),
        "the mount source is the validated name, never a resolved link target: {}",
        lines[run]
    );
    assert_eq!(
        lines[run + 1],
        format!("rm --force spark-model-{instance_id}"),
        "the container started against the swapped source must be removed: {calls}"
    );
}

/// Without a swap the same launch succeeds, so the refusal above is specific to the replaced directory.
#[test]
fn an_unchanged_snapshot_launches_and_keeps_its_container() {
    let root = tempfile::tempdir().unwrap();
    let (docker, log) = gpu_driver_fake_docker(root.path(), "  printf '%s\\n' container-id");
    let backend = gpu_driver_backend(
        root.path(),
        &docker,
        &root.path().join("missing-module-version"),
        &root.path().join("missing-lib"),
    );

    let response = backend
        .execute(&gpu_driver_start_operation(root.path()))
        .expect("an unchanged snapshot launches");

    assert_eq!(response.code, "started", "{response:?}");
    assert!(!fs::read_to_string(&log).unwrap().contains("rm --force"));
}

/// A link already in place at validation is refused before docker is asked for anything.
#[test]
fn a_snapshot_that_is_already_a_symlink_is_refused_before_docker() {
    let root = tempfile::tempdir().unwrap();
    let (docker, log) = gpu_driver_fake_docker(root.path(), "  printf '%s\\n' container-id");
    let backend = gpu_driver_backend(
        root.path(),
        &docker,
        &root.path().join("missing-module-version"),
        &root.path().join("missing-lib"),
    );
    let snapshot = root.path().join("models/snapshots/example/model-32b/rev");
    let elsewhere = root.path().join("elsewhere");
    fs::create_dir_all(&elsewhere).unwrap();
    fs::remove_dir(&snapshot).unwrap();
    std::os::unix::fs::symlink(&elsewhere, &snapshot).unwrap();

    let error = backend
        .execute(&gpu_driver_start_operation(root.path()))
        .expect_err("a linked snapshot is refused");

    assert!(matches!(error, BackendError::InvalidInput(_)), "{error}");
    assert!(!log.exists(), "docker was called: {}", fs::read_to_string(&log).unwrap_or_default());
}
