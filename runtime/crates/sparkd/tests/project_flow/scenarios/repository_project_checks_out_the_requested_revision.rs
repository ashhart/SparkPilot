#[tokio::test]
async fn repository_project_checks_out_the_requested_revision() {
    use spark_project_runner::GitRunner;
    let (h, _, _, device_id) = harness().await;
    let source = h._dir.path().join("source");
    std::fs::create_dir(&source).unwrap();
    let git = CommandGit::new("git");
    git.run_cwd(&source, &["init", "-b", "upstream-default"])
        .unwrap();
    std::fs::write(source.join("README.md"), "requested revision\n").unwrap();
    git.run(&source, &["add", "README.md"]).unwrap();
    git.run(&source, &["commit", "-m", "source"]).unwrap();
    let expected = git.run(&source, &["rev-parse", "HEAD"]).unwrap();
    std::fs::write(source.join("README.md"), "later revision\n").unwrap();
    git.run(&source, &["commit", "-am", "later"]).unwrap();
    h.projects
        .create_project(
            uuid::Uuid::new_v4(),
            "cloned",
            Some(&format!("file://{}", source.display())),
            Some(&expected),
            &device_id,
        )
        .unwrap();
    let project = h.projects.list().unwrap().remove(0);
    assert_eq!(
        std::fs::read_to_string(project.root_path.join("README.md")).unwrap(),
        "requested revision\n"
    );
    assert_eq!(h.projects.protected_head(&project).unwrap(), expected);
    assert_eq!(
        git.run(&project.root_path, &["branch", "--show-current"])
            .unwrap(),
        "main"
    );
}
