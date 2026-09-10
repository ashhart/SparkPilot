#[test]
fn privileged_project_plan_rejects_a_managed_name_that_is_a_symlink_escape() {
    let root = tempfile::tempdir().unwrap();
    let worktree_id = Uuid::new_v4();
    let worktrees = root.path().join("worktrees");
    let outside = root.path().join("outside");
    fs::create_dir_all(&worktrees).unwrap();
    fs::create_dir_all(&outside).unwrap();
    let workspace = worktrees.join(format!("agent-{worktree_id}"));
    std::os::unix::fs::symlink(&outside, &workspace).unwrap();
    let backend = DockerBackend::new("docker", true)
        .with_paths(root.path().join("models"), root.path().join("run"));
    let mut operation = start_project_operation(worktree_id);
    if let PrivilegedOperation::StartProjectContainer {
        workspace_host_path,
        ..
    } = &mut operation
    {
        *workspace_host_path = workspace.display().to_string();
    }

    assert!(matches!(
        backend.plan_start_project_container(&operation),
        Err(BackendError::InvalidInput(_))
    ));
}
