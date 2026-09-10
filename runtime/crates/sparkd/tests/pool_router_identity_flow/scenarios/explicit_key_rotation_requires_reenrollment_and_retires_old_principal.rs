#[tokio::test]
async fn explicit_key_rotation_requires_reenrollment_and_retires_old_principal() {
    let source = node().await;
    let destination = node().await;
    let original = enroll(&source, &destination).await;
    let (old_id, old_key) = private_test_key(&source);
    let expected = original["request_key_fingerprint"].clone();
    let (s, _) = source
        .post(
            &format!("{BASE}/router-identity"),
            &json!({"expected_key_fingerprint":expected}),
            false,
        )
        .await;
    assert_eq!(s, StatusCode::FORBIDDEN);
    let (s, new) = source
        .post(
            &format!("{BASE}/router-identity"),
            &json!({"expected_key_fingerprint":expected}),
            true,
        )
        .await;
    assert_eq!(s, StatusCode::OK, "{new}");
    assert_ne!(new["principal_id"], original["principal_id"]);
    assert_eq!(new["key_generation"], 2);
    assert!(
        transport::request(
            &source.state,
            destination.state.identity.node_id(),
            Method::GET,
            &format!("{BASE}/pools"),
            axum::body::Bytes::new(),
            None
        )
        .await
        .is_err()
    );
    let (status, inventory) = source
        .call("GET", &format!("{BASE}/router-peers"), None, None, false)
        .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(inventory["current_principal_id"], new["principal_id"]);
    assert_eq!(inventory["peers"].as_array().unwrap().len(), 1);
    assert_eq!(
        inventory["peers"][0]["principal_id"],
        original["principal_id"]
    );
    assert_eq!(inventory["peers"][0]["uses_current_key"], false);
    assert_eq!(inventory["peers"][0]["recipient_retirement"], "unconfirmed");
    // A source key replacement cannot revoke a copied key at a destination.
    let headers = sign_headers(
        &destination.state,
        old_id,
        &old_key,
        ("GET", &format!("{BASE}/pools")),
        &[],
        None,
        None,
    );
    assert_eq!(
        destination
            .client
            .get(format!(
                "https://localhost:{}{BASE}/pools",
                destination.address.port()
            ))
            .headers(headers)
            .send()
            .await
            .unwrap()
            .status(),
        StatusCode::OK
    );
    let updated = enroll(&source, &destination).await;
    assert_eq!(updated["principal_id"], new["principal_id"]);
    let (_, inventory) = source
        .call("GET", &format!("{BASE}/router-peers"), None, None, false)
        .await;
    let records = inventory["peers"].as_array().unwrap();
    assert_eq!(records.len(), 2);
    assert!(
        records
            .iter()
            .any(|r| r["principal_id"] == original["principal_id"]
                && r["recipient_retirement"] == "unconfirmed")
    );
    assert!(
        records
            .iter()
            .any(|r| r["principal_id"] == new["principal_id"] && r["uses_current_key"] == true)
    );

    let path = format!("{BASE}/pools");
    let headers = sign_headers(
        &destination.state,
        old_id,
        &old_key,
        ("GET", &path),
        &[],
        None,
        None,
    );
    assert_eq!(
        destination
            .client
            .get(format!(
                "https://localhost:{}{path}",
                destination.address.port()
            ))
            .headers(headers)
            .send()
            .await
            .unwrap()
            .status(),
        StatusCode::UNAUTHORIZED
    );
    source.stop().await;
    destination.stop().await;
}
