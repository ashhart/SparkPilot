/// Reject unknown analysis fields so unsupported caller options cannot be silently ignored.
#[tokio::test]
async fn text_analysis_refuses_unknown_request_fields() {
    let (_h, addr, owner, _observer) = harness().await;
    let client = reqwest::Client::new();
    load_model(&client, addr, &owner).await;

    let (status, response) = post(
        &client,
        addr,
        &owner,
        "/api/v1/inference/analyses",
        json!({ "instruction": "Summarise it.", "text": "hello", "temperature": 1.9 }),
    )
    .await;
    assert_eq!(status, 422, "unknown field: {response}");
    assert_eq!(response["error"]["code"], "ANALYSIS_INPUT_INVALID");
}
