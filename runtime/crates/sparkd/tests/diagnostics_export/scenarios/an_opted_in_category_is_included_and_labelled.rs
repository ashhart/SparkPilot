#[tokio::test]
async fn an_opted_in_category_is_included_and_labelled() {
    let (state, client, _directory) = test_state("owner");
    let bundle = export(state, &client, &["host-paths"]).await;

    let entry = bundle["manifest"]["files"]
        .as_array()
        .unwrap()
        .iter()
        .find(|entry| entry["path"] == "host-paths.json")
        .expect("the opted-in category produced a file");
    assert_eq!(entry["sensitivity"], "identifying");
    assert_eq!(
        bundle["manifest"]["optional_included"],
        json!(["host-paths"])
    );
    assert!(
        bundle["manifest"]["optional_excluded"]
            .as_array()
            .unwrap()
            .iter()
            .all(|id| id != "host-paths")
    );
}
