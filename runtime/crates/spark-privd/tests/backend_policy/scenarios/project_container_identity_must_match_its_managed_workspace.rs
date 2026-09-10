#[test]
fn project_container_identity_must_match_its_managed_workspace() {
    let (_root, backend, mut operation) = managed_project_fixture();
    if let PrivilegedOperation::StartProjectContainer { worktree_id, .. } = &mut operation {
        *worktree_id = Uuid::new_v4();
    }
    assert!(matches!(
        backend.plan_start_project_container(&operation),
        Err(BackendError::InvalidInput(_))
    ));
}
