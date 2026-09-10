#[tokio::test]
async fn no_bundle_path_can_escape_the_archive() {
    let (state, client, _directory) = test_state("owner");
    let bundle = export(state, &client, &["host-paths", "network-addresses"]).await;

    for file in bundle["files"].as_array().unwrap() {
        let path = file["path"].as_str().unwrap();
        assert!(
            sparkd::beneath::safe_components(path).is_ok(),
            "{path} is not a safe archive-relative path"
        );
        assert!(
            !path.contains('/') && !path.contains('\\'),
            "{path} is not a flat archive entry"
        );
        assert!(path.ends_with(".json"), "{path} is not a JSON text entry");
    }
}
