/// Repeated Shortcuts or network retries with one key must start exactly one analysis.
#[tokio::test]
async fn one_idempotency_key_starts_exactly_one_analysis() {
    let (h, addr, owner, _observer) = harness().await;
    let client = reqwest::Client::new();
    load_model(&client, addr, &owner).await;
    let baseline = h.backend.completions();

    let key = uuid::Uuid::new_v4().to_string();
    let body = analysis_body("Some text worth reading twice.");
    let (first_status, first) = signed_json(
        &client,
        addr,
        &owner,
        "POST",
        "/api/v1/inference/analyses",
        Some(body.clone()),
        Some(&key),
    )
    .await;
    let (second_status, second) = signed_json(
        &client,
        addr,
        &owner,
        "POST",
        "/api/v1/inference/analyses",
        Some(body),
        Some(&key),
    )
    .await;

    assert_eq!(first_status, 202, "first: {first}");
    assert_eq!(second_status, 202, "replay: {second}");
    assert_eq!(
        first["id"], second["id"],
        "the replay is the same operation"
    );

    let operation_id = first["id"].as_str().expect("operation id").to_owned();
    let finished = await_operation(&client, addr, &owner, &operation_id).await;
    assert_eq!(finished["state"], "succeeded", "{finished}");

    let (status, operations) = get(&client, addr, &owner, "/api/v1/operations?limit=50").await;
    assert_eq!(status, 200, "{operations}");
    let analyses = operations["items"]
        .as_array()
        .expect("items")
        .iter()
        .filter(|row| row["kind"] == "inference.analysis")
        .count();
    assert_eq!(analyses, 1, "one key must not create two operations");
    assert_eq!(h.backend.completions() - baseline, 1);
}
