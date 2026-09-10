/// SPARK2 signed headers + body for reqwest (§58.3).
fn signed_parts(
    device_key: &p256::ecdsa::SigningKey,
    device_id: &uuid::Uuid,
    method: &str,
    path: &str,
    body: &[u8],
) -> (Vec<(String, String)>, Vec<u8>) {
    let timestamp = rfc3339_now();
    let nonce = fresh_nonce();
    let digest = sha256_hex(body);
    let canonical = auth::canonical(
        method,
        path,
        &timestamp,
        &nonce,
        &digest,
        device_id,
        &SIGNING_NODE_ID,
    );
    let signature: p256::ecdsa::Signature = device_key.sign(canonical.as_bytes());
    let mut headers = vec![
        ("x-spark-node-id".to_owned(), SIGNING_NODE_ID.to_string()),
        ("x-spark-device-id".to_owned(), device_id.to_string()),
        ("x-spark-timestamp".to_owned(), timestamp),
        ("x-spark-nonce".to_owned(), nonce),
        ("x-spark-content-sha256".to_owned(), digest),
        (
            "x-spark-signature".to_owned(),
            base64url_encode(&signature.to_bytes()),
        ),
    ];
    if !body.is_empty() {
        headers.push(("content-type".to_owned(), "application/json".to_owned()));
    }
    (headers, body.to_vec())
}
