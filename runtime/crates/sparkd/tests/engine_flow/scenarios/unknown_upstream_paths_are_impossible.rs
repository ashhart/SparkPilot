#[tokio::test]
async fn unknown_upstream_paths_are_impossible() {
    let (h, addr, key, device_id) = harness(240 << 30).await;
    let client = reqwest::Client::new();

    let operation_id: uuid::Uuid = load_model(&client, addr, &key, &device_id, None).await["id"]
        .as_str()
        .and_then(|s| uuid::Uuid::parse_str(s).ok())
        .expect("load operation id");
    wait_terminal(&h.state, operation_id, Duration::from_secs(10)).await;

    // Arbitrary upstream paths are never routed by the proxy surface.
    let (status, _) = signed_json(
        &client,
        addr,
        &key,
        &device_id,
        "GET",
        "/v1/embeddings",
        None,
    )
    .await;
    assert_eq!(status, reqwest::StatusCode::NOT_FOUND);

    let (status, _) = signed_json(
        &client,
        addr,
        &key,
        &device_id,
        "GET",
        "/v1/collective_rpc",
        None,
    )
    .await;
    assert_eq!(status, reqwest::StatusCode::NOT_FOUND);

    // The chat route itself only accepts POST.
    let (status, _) = signed_json(
        &client,
        addr,
        &key,
        &device_id,
        "GET",
        "/v1/chat/completions",
        None,
    )
    .await;
    assert_eq!(status, reqwest::StatusCode::METHOD_NOT_ALLOWED);
}
