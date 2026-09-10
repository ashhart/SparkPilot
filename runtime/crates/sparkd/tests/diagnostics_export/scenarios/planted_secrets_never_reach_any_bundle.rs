#[tokio::test]
async fn planted_secrets_never_reach_any_bundle() {
    let (state, client, _directory) = test_state("owner");
    // Verify planted secrets remain absent even with the widest owner-selected diagnostic options.
    let bundle = export(state, &client, &["host-paths", "network-addresses"]).await;
    let rendered = serde_json::to_string(&bundle).unwrap();

    for planted in [
        PLANTED_CREDENTIAL_REFERENCE,
        PLANTED_REMOTE_HOSTNAME,
        PLANTED_PROMPT,
    ] {
        assert!(!rendered.contains(planted), "the bundle leaked {planted}");
    }
}
