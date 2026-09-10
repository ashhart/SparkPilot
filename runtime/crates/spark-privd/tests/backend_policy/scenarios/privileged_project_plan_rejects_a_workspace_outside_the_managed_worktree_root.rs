#[test]
fn privileged_project_plan_rejects_a_workspace_outside_the_managed_worktree_root() {
    let (_root, backend, mut operation) = managed_project_fixture();
    if let PrivilegedOperation::StartProjectContainer {
        workspace_host_path,
        ..
    } = &mut operation
    {
        *workspace_host_path = "/etc".into();
    }

    assert!(matches!(
        backend.plan_start_project_container(&operation),
        Err(BackendError::InvalidInput(_))
    ));
}
