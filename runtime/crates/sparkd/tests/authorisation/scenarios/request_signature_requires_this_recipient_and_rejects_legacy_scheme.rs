#[tokio::test]
async fn request_signature_requires_this_recipient_and_rejects_legacy_scheme() {
    let h = harness();
    let key = fresh_key();
    let device = seed_device(&h.state, &key, "observer");
    for legacy in [false, true] {
        let mut request = signed(
            &key,
            &device,
            Method::GET,
            "/api/v1/status",
            &[],
            &fresh_nonce(),
        );
        let header = |name: &str| request.headers().get(name).unwrap().to_str().unwrap();
        let canonical = auth::canonical(
            "GET",
            "/api/v1/status",
            header(auth::HEADER_TIMESTAMP),
            header(auth::HEADER_NONCE),
            header(auth::HEADER_CONTENT_SHA256),
            &device,
            &uuid::Uuid::from_u128(3),
        );
        let bytes = if legacy {
            canonical
                .lines()
                .take(7)
                .collect::<Vec<_>>()
                .join("\n")
                .replacen("SPARK2", "SPARK1", 1)
        } else {
            canonical
        };
        let signature: p256::ecdsa::Signature = key.sign(bytes.as_bytes());
        request.headers_mut().insert(
            auth::HEADER_SIGNATURE,
            HeaderValue::from_str(&base64url_encode(&signature.to_bytes())).unwrap(),
        );
        let response = router(h.state.clone()).oneshot(request).await.unwrap();
        assert_eq!(
            response.status(),
            StatusCode::UNAUTHORIZED,
            "legacy={legacy}"
        );
    }
    let response = router(h.state.clone())
        .oneshot(signed(
            &key,
            &device,
            Method::GET,
            "/api/v1/status",
            &[],
            &fresh_nonce(),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
}
