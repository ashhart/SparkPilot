/// Publish a TLS fingerprint only when serving that exact leaf certificate; plain HTTP must report none.
#[tokio::test]
async fn identity_reports_the_tls_pin_only_when_serving_tls() {
    let (state, client) = test_state();
    let (_, plain) = get_json(state, &client, "/api/v1/identity").await;
    assert!(plain["tls_fingerprint"].is_null(), "plain HTTP has no pin");

    let (state, client) = test_state();
    let fingerprint = "a".repeat(64);
    let secured = state.clone().with_tls_fingerprint(fingerprint.clone());
    let (status, body) = get_json(secured, &client, "/api/v1/identity").await;

    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["tls_fingerprint"], Value::String(fingerprint.clone()));
    // Keep TLS leaf and authority-key fingerprints distinct so clients cannot pin the wrong identity.
    assert_ne!(body["tls_fingerprint"], body["authority_fingerprint"]);
}
