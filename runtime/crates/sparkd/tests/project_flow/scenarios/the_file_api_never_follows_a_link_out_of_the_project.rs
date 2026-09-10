#[tokio::test]
async fn the_file_api_never_follows_a_link_out_of_the_project() {
    let (h, addr, key, device_id) = harness().await;
    let client = reqwest::Client::new();
    let operation_id = create_through_api(&client, addr, &key, &device_id, "symlinks").await;
    assert_eq!(
        wait_op(&h.state, operation_id, Duration::from_secs(20)).await,
        "succeeded"
    );
    let view = h.projects.list().unwrap().remove(0);

    let host_directory = tempfile::tempdir().unwrap();
    let canary = host_directory.path().join("host-only.txt");
    std::fs::write(&canary, b"HOST-ONLY-CANARY").unwrap();
    std::os::unix::fs::symlink(&canary, view.root_path.join("escape.txt")).unwrap();
    std::os::unix::fs::symlink(host_directory.path(), view.root_path.join("escape-dir")).unwrap();
    std::os::unix::fs::symlink("/", view.root_path.join("slash")).unwrap();
    std::fs::write(view.root_path.join("legitimate.txt"), b"in project").unwrap();

    let (status, listed) = signed_json(
        &client,
        addr,
        &key,
        &device_id,
        "GET",
        &format!("/api/v1/projects/{}/files", view.id),
        None,
    )
    .await;
    assert_eq!(status, reqwest::StatusCode::OK, "{listed}");
    let paths: Vec<&str> = listed["items"]
        .as_array()
        .unwrap()
        .iter()
        .map(|item| item["path"].as_str().unwrap())
        .collect();
    assert!(paths.contains(&"legitimate.txt"), "{paths:?}");
    assert!(!paths.iter().any(|path| path.contains("host-only")));
    assert!(
        !paths
            .iter()
            .any(|path| path.starts_with("escape") || path.starts_with("slash"))
    );

    for candidate in [
        "escape.txt",
        "escape-dir/host-only.txt",
        "slash/etc/hosts",
        "../../../etc/hosts",
        "a/../../etc/hosts",
    ] {
        let error = h
            .projects
            .file_read(&view, candidate)
            .expect_err("must refuse");
        assert!(!error.contains("HOST-ONLY-CANARY"));
    }
    assert_eq!(
        h.projects.file_read(&view, "legitimate.txt").unwrap(),
        b"in project"
    );

    let empty = "0".repeat(64);
    let saved = h
        .projects
        .file_save(&view, "escape.txt", b"written by the api", &empty);
    assert!(
        saved
            .as_ref()
            .is_err_and(|error| error.contains("symbolic link")),
        "{saved:?}"
    );
    assert_eq!(std::fs::read(&canary).unwrap(), b"HOST-ONLY-CANARY");
    let existing = h.projects.file_read(&view, "legitimate.txt").unwrap();
    let revision = sparkd::project::revision_of(&existing);
    assert!(
        h.projects
            .file_save(&view, "legitimate.txt", b"edited", &revision)
            .is_ok()
    );

    let (status, body) = signed_json_bytes(
        &client,
        addr,
        &key,
        &device_id,
        "PUT",
        &format!(
            "/api/v1/projects/{}/files/escape-dir/host-only.txt",
            view.id
        ),
        b"overwrite",
        &[("if-match", empty.clone())],
    )
    .await;
    assert_eq!(status, reqwest::StatusCode::UNPROCESSABLE_ENTITY, "{body}");
    assert_eq!(body["error"]["code"], "PROJECT_PATH_INVALID");
    assert_eq!(std::fs::read(&canary).unwrap(), b"HOST-ONLY-CANARY");
}
