#[test]
fn submission_requires_immutable_commit_and_source_digest() {
    let harness = harness();
    let requirements = BuildRequirements::default();
    let attempt = |commit: &str, source: &str| {
        harness.service.submit_build(
            Uuid::new_v4(),
            &harness.project,
            commit,
            source,
            "SparkPilot",
            "Release",
            "generic/platform=macOS",
            vec!["build".into()],
            600,
            &requirements,
            &harness.owner,
        )
    };
    assert_eq!(
        attempt("main", SOURCE),
        Err("BUILD_COMMIT_NOT_IMMUTABLE".into())
    );
    assert_eq!(
        attempt(COMMIT, "not-a-digest"),
        Err("BUILD_SOURCE_DIGEST_INVALID".into())
    );

    let invalid_recipe = |scheme: &str, actions: Vec<String>| {
        harness.service.submit_build(
            Uuid::new_v4(),
            &harness.project,
            COMMIT,
            SOURCE,
            scheme,
            "Release",
            "generic/platform=macOS",
            actions,
            600,
            &requirements,
            &harness.owner,
        )
    };
    assert_eq!(
        invalid_recipe("App\nINJECTED=1", vec!["build".into()]),
        Err("scheme out of range".into())
    );
    assert_eq!(
        invalid_recipe("App", vec!["build".into(), "test".into(), "build".into()]),
        Err("actions out of range".into())
    );
}
