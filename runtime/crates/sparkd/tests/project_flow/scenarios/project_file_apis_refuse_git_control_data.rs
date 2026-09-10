#[tokio::test]
async fn project_file_apis_refuse_git_control_data() {
    let (h, _, _, device_id) = harness().await;
    h.projects
        .create_project(uuid::Uuid::new_v4(), "control-data", None, None, &device_id)
        .unwrap();
    let project = h.projects.list().unwrap().remove(0);
    for path in [".git/config", ".GIT/config", "nested/.git/config", ".git"] {
        assert!(
            h.projects.file_read(&project, path).is_err(),
            "read accepted {path}"
        );
        assert!(
            h.projects
                .file_save(&project, path, b"benign fixture", REVISION_EMPTY)
                .is_err(),
            "write accepted {path}"
        );
    }
}
