async fn signed_event_stream(
    client: &reqwest::Client,
    addr: SocketAddr,
    key: &p256::ecdsa::SigningKey,
    device_id: &uuid::Uuid,
    cursor: i64,
) -> reqwest::Response {
    let (headers, body) = signed_parts(key, device_id, "GET", "/api/v1/events", b"");
    let mut request = client
        .get(format!("http://{addr}/api/v1/events"))
        .header("last-event-id", cursor.to_string())
        .body(body);
    for (name, value) in headers {
        request = request.header(name, value);
    }
    request.send().await.expect("event stream")
}
