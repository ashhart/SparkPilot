/// A fake docker with no existing container whose `run` performs the swap the service would race with.
fn workspace_swapping_docker(
    root: &std::path::Path,
    run_script: &str,
) -> (std::path::PathBuf, std::path::PathBuf) {
    let docker = root.join("docker");
    let log = root.join("docker.log");
    let script = format!(
        "#!/bin/sh\nprintf '%s\\n' \"$*\" >> '{}'\ncase \"$1\" in\n  inspect) exit 1 ;;\n  run)\n{}\n  ;;\nesac\nexit 0\n",
        log.display(),
        run_script
    );
    fs::write(&docker, script).unwrap();
    fs::set_permissions(&docker, fs::Permissions::from_mode(0o755)).unwrap();
    (docker, log)
}

#[test]
fn a_workspace_swapped_for_a_symlink_during_launch_is_torn_down() {
    let root = tempfile::tempdir().unwrap();
    let worktree_id = Uuid::new_v4();
    let workspace = root
        .path()
        .join("worktrees")
        .join(format!("agent-{worktree_id}"));
    fs::create_dir_all(&workspace).unwrap();
    let elsewhere = root.path().join("elsewhere");
    fs::create_dir_all(&elsewhere).unwrap();
    let swap = format!(
        "    mv '{workspace}' '{moved}' && ln -s '{elsewhere}' '{workspace}'\n    printf '%s\\n' container-id",
        workspace = workspace.display(),
        moved = root.path().join("moved-away").display(),
        elsewhere = elsewhere.display(),
    );
    let (docker, log) = workspace_swapping_docker(root.path(), &swap);
    let backend = DockerBackend::new(docker.to_string_lossy(), false)
        .with_paths(root.path().join("models"), root.path().join("run"));
    let mut operation = start_project_operation(worktree_id);
    if let PrivilegedOperation::StartProjectContainer {
        workspace_host_path,
        ..
    } = &mut operation
    {
        *workspace_host_path = workspace.display().to_string();
    }

    let error = backend
        .execute(&operation)
        .expect_err("a swapped workspace is refused");

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
        lines[run].contains(&format!("--volume={}:/workspace:rw", workspace.display())),
        "{}",
        lines[run]
    );
    assert_eq!(
        lines[run + 1],
        format!("rm --force spark-project-{worktree_id}"),
        "{calls}"
    );

    // The same launch without a swap keeps its container.
    fs::remove_file(&workspace).unwrap();
    fs::rename(root.path().join("moved-away"), &workspace).unwrap();
    let (docker, log) =
        workspace_swapping_docker(root.path(), "    printf '%s\\n' container-id");
    fs::remove_file(&log).unwrap();
    let backend = DockerBackend::new(docker.to_string_lossy(), false)
        .with_paths(root.path().join("models"), root.path().join("run"));
    let response = backend.execute(&operation).expect("an unchanged workspace launches");
    assert_eq!(response.code, "started_project", "{response:?}");
    assert!(!fs::read_to_string(&log).unwrap().contains("rm --force"));
}
