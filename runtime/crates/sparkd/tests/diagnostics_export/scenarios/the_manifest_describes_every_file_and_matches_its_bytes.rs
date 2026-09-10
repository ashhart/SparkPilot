#[tokio::test]
async fn the_manifest_describes_every_file_and_matches_its_bytes() {
    let (state, client, _directory) = test_state("owner");
    let bundle = export(state, &client, &["host-paths", "network-addresses"]).await;

    let files = bundle["files"].as_array().unwrap();
    let manifest = bundle["manifest"]["files"].as_array().unwrap();
    assert_eq!(files.len(), manifest.len(), "manifest and files disagree");

    for file in files {
        let path = file["path"].as_str().unwrap();
        let entry = manifest
            .iter()
            .find(|entry| entry["path"] == path)
            .unwrap_or_else(|| panic!("{path} has no manifest entry"));
        let content = file["content"].as_str().unwrap();
        assert_eq!(entry["sensitivity"], file["sensitivity"]);
        assert!(entry["description"].as_str().is_some_and(|d| !d.is_empty()));
        assert_eq!(entry["bytes"], content.len());
        assert_eq!(entry["sha256"], sha256_hex(content.as_bytes()));
        // Every file is UTF-8 text carrying a JSON document the owner can read.
        serde_json::from_str::<Value>(content)
            .unwrap_or_else(|error| panic!("{path} is not readable JSON: {error}"));
    }
}
