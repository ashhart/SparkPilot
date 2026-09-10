/// Cancellation must drop the upstream generation and finish the operation as cancelled rather than succeeded.
#[tokio::test]
async fn cancelling_a_text_analysis_stops_the_generation() {
    let (h, addr, owner, _observer) = harness().await;
    let client = reqwest::Client::new();
    load_model(&client, addr, &owner).await;
    h.backend.set_non_stream_delay(Duration::from_secs(30));

    let (status, accepted) = post(
        &client,
        addr,
        &owner,
        "/api/v1/inference/analyses",
        analysis_body("This one takes a while."),
    )
    .await;
    assert_eq!(status, 202, "{accepted}");
    let operation_id = accepted["id"].as_str().expect("operation id").to_owned();

    let (status, cancelled) = post(
        &client,
        addr,
        &owner,
        &format!("/api/v1/operations/{operation_id}/cancel"),
        json!({}),
    )
    .await;
    assert_eq!(status, 202, "{cancelled}");

    let finished = await_operation(&client, addr, &owner, &operation_id).await;
    assert_eq!(finished["state"], "cancelled", "{finished}");
    assert_eq!(finished["result"], Value::Null, "no partial result is kept");
}
