#[test]
fn git_add_rejects_an_escaping_path_before_invoking_git() {
    let dir = tempfile::tempdir().unwrap();
    let runtime = ToolRuntime::default();
    let result = runtime.execute(
        &ToolExecutionTarget {
            project_id: uuid::Uuid::new_v4(),
            container_id: "spark-project-00000000-0000-0000-0000-000000000000",
            worktree: dir.path(),
        },
        &AgentToolCall::Git {
            op: GitOp::Add {
                path: "../outside".into(),
            },
        },
    );
    assert!(!result.ok);
    assert!(
        result.output.contains("path not allowed"),
        "{}",
        result.output
    );
}
