#[tokio::test]
async fn the_default_bundle_carries_nothing_the_owner_did_not_ask_for() {
    let (state, client, _directory) = test_state("owner");
    let bundle = export(state, &client, &[]).await;

    for entry in bundle["manifest"]["files"].as_array().unwrap() {
        assert_eq!(
            entry["sensitivity"], "operational",
            "{} is in the default bundle with a sensitive class",
            entry["path"]
        );
    }
    assert!(
        bundle["manifest"]["optional_included"]
            .as_array()
            .unwrap()
            .is_empty()
    );
    assert!(
        !bundle["manifest"]["optional_excluded"]
            .as_array()
            .unwrap()
            .is_empty(),
        "the manifest must name what was left out, not only what was put in"
    );
}
