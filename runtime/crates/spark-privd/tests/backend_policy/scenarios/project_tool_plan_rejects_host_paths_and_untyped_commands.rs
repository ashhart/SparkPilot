#[test]
fn project_tool_plan_rejects_host_paths_and_untyped_commands() {
    let backend = DockerBackend::new("docker", true);
    let project_id = Uuid::new_v4();
    let container_id = format!("spark-project-{}", Uuid::new_v4());
    for tool in [
        ProjectToolOperation::ReadFile {
            path: "../etc/passwd".into(),
        },
        ProjectToolOperation::RunCommand {
            argv: vec!["sh".into(), "-c".into(), "id".into()],
        },
        ProjectToolOperation::Git {
            operation: ProjectGitOperation::Add {
                path: "/tmp/host".into(),
            },
        },
    ] {
        let result = backend.execute(&PrivilegedOperation::RunProjectTool {
            request_id: Uuid::new_v4(),
            project_id,
            container_id: container_id.clone(),
            tool,
        });
        assert!(matches!(result, Err(BackendError::InvalidInput(_))));
    }
}
