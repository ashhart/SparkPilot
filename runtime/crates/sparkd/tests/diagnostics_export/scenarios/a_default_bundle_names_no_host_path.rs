#[tokio::test]
async fn a_default_bundle_names_no_host_path() {
    let (state, client, directory) = test_state("owner");
    let root = directory.path().display().to_string();
    let bundle = export(state.clone(), &client, &[]).await;
    assert!(
        !serde_json::to_string(&bundle).unwrap().contains(&root),
        "a default section disclosed the data directory"
    );

    // Opting in puts it in exactly one file, and that file is labelled.
    let opted = export(state, &client, &["host-paths"]).await;
    let carrying: Vec<&str> = opted["files"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|file| file["content"].as_str().unwrap().contains(&root))
        .map(|file| file["path"].as_str().unwrap())
        .collect();
    assert_eq!(carrying, vec!["host-paths.json"]);
}
