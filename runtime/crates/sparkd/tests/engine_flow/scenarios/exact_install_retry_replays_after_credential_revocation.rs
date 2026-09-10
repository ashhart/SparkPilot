#[tokio::test]
async fn exact_install_retry_replays_after_credential_revocation() {
    let (h, addr, key, device_id) = harness(240 << 30).await;
    let credential_id = {
        let connection = h.state.database.as_ref().expect("db").lock();
        sparkd::credentials::CredentialStore::new(h._dir.path())
            .store(
                &connection,
                "huggingface",
                "test token",
                "hf_test_token",
                device_id,
            )
            .unwrap()
    };
    let client = reqwest::Client::new();
    let key_value = uuid::Uuid::new_v4().to_string();
    let body = previewed_apply_body(
        &client,
        addr,
        &key,
        &device_id,
        "POST",
        "/api/v1/models/example%2Fnot-installed/install",
        Some(json!({ "provider_credential_id": credential_id.to_string() })),
    )
    .await
    .unwrap()
    .unwrap();
    let path = "/api/v1/models/example%2Fnot-installed/install";
    let (first_status, first_body) = signed_json_with_idempotency(
        &client,
        addr,
        &key,
        &device_id,
        "POST",
        path,
        Some(body.clone()),
        Some(&key_value),
    )
    .await;
    assert_eq!(first_status, reqwest::StatusCode::ACCEPTED, "{first_body}");
    {
        let connection = h.state.database.as_ref().expect("db").lock();
        sparkd::credentials::CredentialStore::new(h._dir.path())
            .revoke(&connection, credential_id)
            .unwrap();
    }

    let (replay_status, replay_body) = signed_json_with_idempotency(
        &client,
        addr,
        &key,
        &device_id,
        "POST",
        path,
        Some(body),
        Some(&key_value),
    )
    .await;

    assert_eq!(
        replay_status,
        reqwest::StatusCode::ACCEPTED,
        "{replay_body}"
    );
    assert_eq!(replay_body, first_body);
}
