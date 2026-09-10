/// Refuse MODEL_NOT_LOADED before queuing analysis against an absent engine.
#[tokio::test]
async fn text_analysis_refuses_when_no_model_is_loaded() {
    let (_h, addr, owner, _observer) = harness().await;
    let client = reqwest::Client::new();

    let (status, response) = post(
        &client,
        addr,
        &owner,
        "/api/v1/inference/analyses",
        analysis_body("Nothing can read this yet."),
    )
    .await;
    assert_eq!(status, 404, "{response}");
    assert_eq!(response["error"]["code"], "MODEL_NOT_LOADED");
}
