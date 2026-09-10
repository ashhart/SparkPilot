#[tokio::test]
async fn project_create_rejects_non_https_sources_before_dispatch() {
    let git = Arc::new(RecordingProjectGit::default());
    let (h, address, _, _) = harness_with_git(git.clone()).await;
    let (key, device) = project_developer(&h);
    let client = reqwest::Client::new();
    for source in [
        "file:///unused-local-mirror.git",
        "http://example.invalid/repo.git",
        "ssh://example.invalid/repo.git",
        "git://example.invalid/repo.git",
        "/unused-local-mirror",
        "https://user:password@example.invalid/repo.git",
    ] {
        let (status, response) = signed_json(
            &client,
            address,
            &key,
            &device,
            "POST",
            "/api/v1/projects",
            Some(json!({"name":"remote-only", "repository_url": source})),
        )
        .await;
        assert_eq!(
            status,
            reqwest::StatusCode::UNPROCESSABLE_ENTITY,
            "{source}: {response}"
        );
        assert_eq!(response["error"]["code"], "REPOSITORY_URL_UNSUPPORTED");
    }
    let operations: i64 = h
        .state
        .database
        .as_ref()
        .unwrap()
        .lock()
        .query_row("SELECT count(*) FROM operations", [], |row| row.get(0))
        .unwrap();
    assert_eq!(operations, 0, "rejected sources cannot create jobs");
    assert!(git.0.lock().is_empty(), "no rejected source reaches Git");
    assert!(h.projects.list().unwrap().is_empty());
}
