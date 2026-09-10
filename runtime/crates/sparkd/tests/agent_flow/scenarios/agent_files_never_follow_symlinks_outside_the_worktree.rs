#[test]
fn agent_files_never_follow_symlinks_outside_the_worktree() {
    let directory = tempfile::tempdir().unwrap();
    let worktree = directory.path().join("worktree");
    let outside = directory.path().join("outside");
    std::fs::create_dir_all(&worktree).unwrap();
    std::fs::create_dir_all(&outside).unwrap();
    let secret = outside.join("secret.txt");
    std::fs::write(&secret, "host secret").unwrap();
    std::os::unix::fs::symlink(&outside, worktree.join("escape")).unwrap();
    let runtime = ToolRuntime::default();
    let target = ToolExecutionTarget {
        project_id: uuid::Uuid::new_v4(),
        container_id: "spark-project-00000000-0000-0000-0000-000000000000",
        worktree: &worktree,
    };

    for call in [
        AgentToolCall::ReadFile {
            path: "escape/secret.txt".into(),
        },
        AgentToolCall::SearchFiles {
            path: "escape".into(),
            pattern: "host secret".into(),
        },
        AgentToolCall::WriteFile {
            path: "escape/replaced.txt".into(),
            content: "agent write".into(),
        },
    ] {
        let result = runtime.execute(&target, &call);
        assert!(
            !result.ok,
            "symlink escape unexpectedly succeeded: {call:?}"
        );
        assert!(
            result.denied.is_some(),
            "refusal was not classified as denied"
        );
    }
    assert!(!outside.join("replaced.txt").exists());

    let deletion = runtime.execute(
        &target,
        &AgentToolCall::DeleteFile {
            path: "escape/secret.txt".into(),
        },
    );
    assert!(!deletion.ok);
    assert_eq!(std::fs::read_to_string(secret).unwrap(), "host secret");
}
