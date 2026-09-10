#[tokio::test]
async fn runtime_bundle_requires_presence_before_any_bytes_are_staged() {
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

    let (status, error) = send(
        state.clone(),
        signed_request(&client, Method::POST, "/api/v1/system/updates", body, false),
    )
    .await;

    assert_eq!(status, StatusCode::FORBIDDEN, "{error}");
    assert!(!state.runtime_update_staging_root.exists());
    assert!(observed.lock().unwrap().is_empty());
}
