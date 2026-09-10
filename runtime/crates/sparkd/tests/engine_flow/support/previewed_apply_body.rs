async fn previewed_apply_body(
    client: &reqwest::Client,
    base: SocketAddr,
    device_key: &p256::ecdsa::SigningKey,
    device_id: &uuid::Uuid,
    method: &str,
    path: &str,
    body: Option<Value>,
) -> Result<Option<Value>, (reqwest::StatusCode, Value)> {
    let preview_path = if method == "POST" && path == "/api/v1/inference/load" {
        Some("/api/v1/inference/load/preview".to_owned())
    } else if method == "POST" && path == "/api/v1/inference/unload" {
        Some("/api/v1/inference/unload/preview".to_owned())
    } else if method == "POST" && path.ends_with("/install") {
        Some(format!("{path}/preview"))
    } else if method == "DELETE" && path.starts_with("/api/v1/models/") {
        Some(format!("{path}/remove/preview"))
    } else {
        None
    };
    let Some(preview_path) = preview_path else {
        return Ok(body);
    };
    if body
        .as_ref()
        .and_then(|value| value.get("accepted_preview_digest"))
        .is_some()
    {
        return Ok(body);
    }
    let preview_body = if method == "DELETE" {
        None
    } else {
        body.clone().or_else(|| Some(json!({})))
    };
    let response = signed_json_with_idempotency(
        client,
        base,
        device_key,
        device_id,
        "POST",
        &preview_path,
        preview_body,
        Some(&uuid::Uuid::new_v4().to_string()),
    )
    .await;
    if response.0 != reqwest::StatusCode::OK {
        return Err(response);
    }
    let digest = response.1["preview_digest"]
        .as_str()
        .expect("preview digest")
        .to_owned();
    let mut apply = body.unwrap_or_else(|| json!({}));
    apply
        .as_object_mut()
        .expect("model apply body is an object")
        .insert("accepted_preview_digest".into(), Value::String(digest));
    Ok(Some(apply))
}
