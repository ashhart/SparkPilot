#[tokio::test]
async fn project_create_accepts_https_through_the_controlled_runner() {
    let git = Arc::new(RecordingProjectGit::default());
    let (h, address, _, _) = harness_with_git(git.clone()).await;
    let (key, device) = project_developer(&h);
    let client = reqwest::Client::new();
    let source = "https://example.invalid/team/repository.git";
    let (status, response) = signed_json(
        &client,
        address,
        &key,
        &device,
        "POST",
        "/api/v1/projects",
        Some(json!({"name":"remote-project", "repository_url": source})),
    )
    .await;
    assert_eq!(status, reqwest::StatusCode::ACCEPTED, "{response}");
    let operation = uuid::Uuid::parse_str(response["id"].as_str().unwrap()).unwrap();
    assert_eq!(
        wait_op(&h.state, operation, Duration::from_secs(5)).await,
        "succeeded"
    );
    assert!(git.0.lock().iter().any(|arguments| {
        arguments.first().is_some_and(|value| value == "clone")
            && arguments.iter().any(|value| value == source)
    }));
    assert_eq!(
        h.projects
            .list()
            .unwrap()
            .remove(0)
            .repository_url
            .as_deref(),
        Some(source)
    );
}
