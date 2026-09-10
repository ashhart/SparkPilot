#[tokio::test]
async fn the_capability_flag_advertises_the_route() {
    let peer = peer("owner");
    let mut nonce = [0; 24];
    rand::rng().fill_bytes(&mut nonce);
    let nonce = base64url_encode(&nonce);
    let timestamp = time::OffsetDateTime::now_utc()
        .format(&time::format_description::well_known::Rfc3339)
        .unwrap();
    let content_sha256 = sha256_hex(b"");
    let path = "/api/v1/capabilities";
    let canonical = auth::canonical(
        "GET",
        path,
        &timestamp,
        &nonce,
        &content_sha256,
        &peer.device_id,
        &SIGNING_NODE_ID,
    );
    let signature: p256::ecdsa::Signature = peer.device_key.sign(canonical.as_bytes());
    let request = Request::builder()
        .method(Method::GET)
        .uri(path)
        .header(auth::HEADER_DEVICE_ID, peer.device_id.to_string())
        .header("x-spark-node-id", SIGNING_NODE_ID.to_string())
        .header(auth::HEADER_TIMESTAMP, &timestamp)
        .header(auth::HEADER_NONCE, &nonce)
        .header(auth::HEADER_CONTENT_SHA256, &content_sha256)
        .header(
            auth::HEADER_SIGNATURE,
            base64url_encode(&signature.to_bytes()),
        )
        .body(axum::body::Body::empty())
        .unwrap();
    let (status, body) = send(&peer, request).await;
    assert_eq!(status, StatusCode::OK, "{body}");
    assert_eq!(body["features"]["model_profile_reenable"], json!(true));
}
