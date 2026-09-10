#[tokio::test]
async fn identity_returns_full_record_for_paired_device() {
    let (state, client) = test_state();
    let (status, body) = get_json(state, &client, "/api/v1/identity").await;

    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["role"], Value::String("standalone".into()));
    assert_eq!(body["runtime_version"], Value::String("0.1.0".into()));
    assert!(body["authority_fingerprint"].is_string());
    assert!(body.get("tls_fingerprint").is_some());
    assert!(body["tls_fingerprint"].is_null());
    assert_eq!(body["name"], Value::String("test-node".into()));

    // Report tls_fingerprint explicitly as null for plain HTTP rather than omitting the field.
    assert!(
        body.get("tls_fingerprint").is_some(),
        "tls_fingerprint is part of the Identity contract"
    );
    assert!(body["tls_fingerprint"].is_null());
}
