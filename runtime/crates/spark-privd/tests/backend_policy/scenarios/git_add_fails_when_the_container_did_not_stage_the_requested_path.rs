#[test]
fn git_add_fails_when_the_container_did_not_stage_the_requested_path() {
    let root = tempfile::tempdir().unwrap();
    let docker = root.path().join("docker");
    let project_id = Uuid::new_v4();
    fs::write(
        &docker,
        format!(
            "#!/bin/sh\nif [ \"$1\" = inspect ]; then printf '%s\\n' '{project_id}'; exit 0; fi\ncase \"$*\" in *--cached*) printf 'other.txt\\0';; esac\nexit 0\n"
        ),
    )
    .unwrap();
    fs::set_permissions(&docker, fs::Permissions::from_mode(0o755)).unwrap();
    let backend = DockerBackend::new(docker.to_string_lossy(), false);
    let result = backend.execute(&PrivilegedOperation::RunProjectTool {
        request_id: Uuid::new_v4(),
        project_id,
        container_id: format!("spark-project-{}", Uuid::new_v4()),
        tool: ProjectToolOperation::Git {
            operation: ProjectGitOperation::Add {
                path: "wanted.txt".into(),
            },
        },
    });
    assert!(
        matches!(result, Err(BackendError::Failure(message)) if message.contains("did not stage"))
    );
}
