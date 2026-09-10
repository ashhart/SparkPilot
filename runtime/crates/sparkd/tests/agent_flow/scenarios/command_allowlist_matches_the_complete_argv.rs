#[test]
fn command_allowlist_matches_the_complete_argv() {
    let directory = tempfile::tempdir().unwrap();
    let runtime = ToolRuntime::new(AgentPolicy {
        allowlist_commands: vec!["cargo test".into()],
    });
    let target = ToolExecutionTarget {
        project_id: uuid::Uuid::new_v4(),
        container_id: "spark-project-00000000-0000-0000-0000-000000000000",
        worktree: directory.path(),
    };

    let result = runtime.execute(
        &target,
        &AgentToolCall::RunCommand {
            command: "cargo test --manifest-path /tmp/host/Cargo.toml".into(),
        },
    );

    assert!(!result.ok);
    assert!(result.denied.is_some());
}
