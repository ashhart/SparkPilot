#[tokio::test]
async fn cold_terminal_uses_a_managed_isolated_checkout() {
    let (h, _, _, device_id) = harness().await;
    h.projects
        .create_project(
            uuid::Uuid::new_v4(),
            "cold-terminal",
            None,
            None,
            &device_id,
        )
        .unwrap();
    let project = h.projects.list().unwrap().remove(0);
    std::fs::create_dir(project.root_path.join(".devcontainer")).unwrap();
    std::fs::write(project.root_path.join(".devcontainer/devcontainer.json"), r#"{"image":"test/image@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}"#).unwrap();
    let container = h.projects.ensure_project_container(&project).unwrap();
    let workspace = std::path::Path::new(&container.worktree_path);
    assert_eq!(
        workspace.parent(),
        Some(h._dir.path().join("worktrees").as_path())
    );
    assert!(
        workspace
            .file_name()
            .unwrap()
            .to_str()
            .unwrap()
            .starts_with("agent-")
    );
    assert!(workspace.join(".git").is_dir());
    assert_ne!(workspace, project.root_path);
}
