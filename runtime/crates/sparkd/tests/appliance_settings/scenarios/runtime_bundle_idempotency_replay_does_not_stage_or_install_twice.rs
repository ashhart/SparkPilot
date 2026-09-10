#[tokio::test]
async fn runtime_bundle_idempotency_replay_does_not_stage_or_install_twice() {
    let (state, client, observed) = test_state("owner");
    let encode = |bytes: &[u8]| base64::engine::general_purpose::STANDARD.encode(bytes);
    let body = json!({
        "system_packages": false,
        "firmware": false,
        "runtime_release_bundle": {
            "release_id": "dev-0.2.0",
            "manifest_base64": encode(b"manifest"),
            "package_base64": encode(b"package"),
            "signature_base64": encode(b"signature"),
        }
    });
    let idempotency_key = uuid::Uuid::new_v4().to_string();
    let request = |client: &TestClient| {
        let mut request = signed_request(
            client,
            Method::POST,
            "/api/v1/system/updates",
            body.clone(),
            true,
        );
        request.headers_mut().insert(
            "idempotency-key",
            idempotency_key.parse().expect("valid header value"),
        );
        request
    };

    let (first_status, first) = send(state.clone(), request(&client)).await;
    assert_eq!(first_status, StatusCode::ACCEPTED, "{first}");
    wait_for(&observed, "install_runtime_update");
    let staged_package = state
        .runtime_update_staging_root
        .join("dev-0.2.0")
        .join(spark_privd::update::STAGED_PACKAGE);
    std::fs::write(&staged_package, b"proof-the-worker-did-not-run-again").unwrap();

    let (replay_status, replay) = send(state, request(&client)).await;
    assert_eq!(replay_status, StatusCode::ACCEPTED, "{replay}");
    assert_eq!(
        std::fs::read(staged_package).unwrap(),
        b"proof-the-worker-did-not-run-again"
    );
    assert_eq!(
        observed
            .lock()
            .unwrap()
            .iter()
            .filter(|kind| kind.as_str() == "install_runtime_update")
            .count(),
        1
    );
}
