async fn load_model(
    client: &reqwest::Client,
    addr: SocketAddr,
    key: &p256::ecdsa::SigningKey,
    device_id: &uuid::Uuid,
    replace_active: Option<bool>,
) -> Value {
    let mut body = json!({ "model_id": "example/model-32b", "profile_id": "balanced-16k" });
    if let Some(replace) = replace_active {
        body["replace_active"] = Value::Bool(replace);
    }
    let (status, response) = signed_json(
        client,
        addr,
        key,
        device_id,
        "POST",
        "/api/v1/inference/load",
        Some(body),
    )
    .await;
    assert_eq!(status, reqwest::StatusCode::ACCEPTED, "{response}");
    response
}
