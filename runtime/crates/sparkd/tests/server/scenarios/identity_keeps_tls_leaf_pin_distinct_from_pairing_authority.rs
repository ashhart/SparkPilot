#[tokio::test]
async fn identity_keeps_tls_leaf_pin_distinct_from_pairing_authority() {
    let (state, client) = test_state();
    let tls_fingerprint = "a".repeat(64);
    let (status, body) = get_json(
        state.with_tls_fingerprint(tls_fingerprint.clone()),
        &client,
        "/api/v1/identity",
    )
    .await;

    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["tls_fingerprint"], tls_fingerprint);
    assert_ne!(body["tls_fingerprint"], body["authority_fingerprint"]);
}
