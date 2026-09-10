/// Persist analysis text on one durable operation rather than relying on a live intent process.
#[tokio::test]
async fn text_analysis_returns_a_durable_operation_carrying_the_result() {
    let (h, addr, owner, _observer) = harness().await;
    let client = reqwest::Client::new();
    load_model(&client, addr, &owner).await;
    // Count generations after loading because readiness verification itself performs a completion.
    let baseline = h.backend.completions();

    let (status, accepted) = post(
        &client,
        addr,
        &owner,
        "/api/v1/inference/analyses",
        analysis_body("Revenue rose. Costs fell. Morale is unchanged."),
    )
    .await;
    assert_eq!(status, 202, "analysis accepted: {accepted}");
    assert_eq!(accepted["kind"], "inference.analysis");
    assert_eq!(accepted["cancellable"], true);

    let operation_id = accepted["id"].as_str().expect("operation id").to_owned();
    let finished = await_operation(&client, addr, &owner, &operation_id).await;
    assert_eq!(finished["state"], "succeeded", "analysis: {finished}");
    assert_eq!(
        finished["result"]["text"], "Hello from the mock engine.",
        "the stored result is the model's answer: {finished}"
    );
    assert_eq!(finished["result"]["model_id"], MODEL_ID);
    assert_eq!(h.backend.completions() - baseline, 1);
}
