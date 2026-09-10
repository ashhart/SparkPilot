/// Publish durable-analysis capability so clients can avoid unsupported requests.
#[tokio::test]
async fn capabilities_publish_durable_text_analysis() {
    let (_h, addr, owner, _observer) = harness().await;
    let client = reqwest::Client::new();

    let (status, capabilities) = get(&client, addr, &owner, "/api/v1/capabilities").await;
    assert_eq!(status, 200, "{capabilities}");
    assert_eq!(
        capabilities["features"]["durable_text_analysis"], true,
        "this runtime has an engine and a database: {capabilities}"
    );
}
