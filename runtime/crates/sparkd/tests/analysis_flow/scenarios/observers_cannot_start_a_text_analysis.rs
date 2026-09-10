/// Reject observers because document inference requires User-or-higher capability (§61).
#[tokio::test]
async fn observers_cannot_start_a_text_analysis() {
    let (h, addr, owner, observer) = harness().await;
    let client = reqwest::Client::new();
    load_model(&client, addr, &owner).await;
    let baseline = h.backend.completions();

    let (status, response) = post(
        &client,
        addr,
        &observer,
        "/api/v1/inference/analyses",
        analysis_body("Not for an observer."),
    )
    .await;
    assert_eq!(status, 403, "{response}");
    assert_eq!(response["error"]["code"], "ROLE_FORBIDDEN");
    assert_eq!(
        h.backend.completions() - baseline,
        0,
        "nothing reached the engine"
    );
}
