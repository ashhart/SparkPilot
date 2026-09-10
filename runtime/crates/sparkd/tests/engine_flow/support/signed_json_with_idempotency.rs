#[allow(clippy::too_many_arguments)]
async fn signed_json_with_idempotency(
    client: &reqwest::Client,
    base: SocketAddr,
    device_key: &p256::ecdsa::SigningKey,
    device_id: &uuid::Uuid,
    method: &str,
    path: &str,
    body: Option<Value>,
    idempotency_key: Option<&str>,
) -> (reqwest::StatusCode, Value) {
    let body_bytes = body
        .map(|b| serde_json::to_vec(&b).unwrap())
        .unwrap_or_default();
    let (headers, bytes) = signed_parts(device_key, device_id, method, path, &body_bytes);
    let url = format!("http://{base}{path}");
    let mut builder = client.request(
        reqwest::Method::from_bytes(method.as_bytes()).unwrap(),
        &url,
    );
    for (name, value) in headers {
        builder = builder.header(name, value);
    }
    if let Some(key) = idempotency_key {
        builder = builder.header("idempotency-key", key);
    }
    builder = builder.body(bytes);
    let response = builder.send().await.expect("send");
    let status = response.status();
    let body: Value = response.json().await.unwrap_or(Value::Null);
    (status, body)
}
