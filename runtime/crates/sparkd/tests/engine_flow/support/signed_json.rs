async fn signed_json(
    client: &reqwest::Client,
    base: SocketAddr,
    device_key: &p256::ecdsa::SigningKey,
    device_id: &uuid::Uuid,
    method: &str,
    path: &str,
    body: Option<Value>,
) -> (reqwest::StatusCode, Value) {
    let body =
        match previewed_apply_body(client, base, device_key, device_id, method, path, body).await {
            Ok(body) => body,
            Err(response) => return response,
        };
    let idempotency_key = if matches!(method, "POST" | "PUT" | "PATCH" | "DELETE") {
        Some(uuid::Uuid::new_v4().to_string())
    } else {
        None
    };
    signed_json_with_idempotency(
        client,
        base,
        device_key,
        device_id,
        method,
        path,
        body,
        idempotency_key.as_deref(),
    )
    .await
}
