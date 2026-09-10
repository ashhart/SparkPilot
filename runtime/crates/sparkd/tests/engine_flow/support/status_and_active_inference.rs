async fn status_and_active_inference(
    client: &reqwest::Client,
    addr: SocketAddr,
    key: &p256::ecdsa::SigningKey,
    device_id: &uuid::Uuid,
) -> (Value, Value) {
    let (status_code, status) =
        signed_json(client, addr, key, device_id, "GET", "/api/v1/status", None).await;
    assert_eq!(status_code, reqwest::StatusCode::OK, "{status}");
    let (active_code, active) = signed_json(
        client,
        addr,
        key,
        device_id,
        "GET",
        "/api/v1/inference/active",
        None,
    )
    .await;
    assert_eq!(active_code, reqwest::StatusCode::OK, "{active}");
    assert_eq!(status["inference"], active);
    (status, active)
}
