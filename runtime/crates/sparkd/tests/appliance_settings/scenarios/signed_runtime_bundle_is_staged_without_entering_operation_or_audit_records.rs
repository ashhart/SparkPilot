#[tokio::test]
async fn signed_runtime_bundle_is_staged_without_entering_operation_or_audit_records() {
    let (state, client, observed) = test_state("owner");
    let manifest = b"signed release manifest";
    let package = b"signed deb bytes that must not be audited";
    let signature = b"detached signature";
    let encode = |bytes: &[u8]| base64::engine::general_purpose::STANDARD.encode(bytes);
    let body = json!({
        "system_packages": false,
        "firmware": false,
        "runtime_release_id": "dev-0.2.0",
        "runtime_release_bundle": {
            "release_id": "dev-0.2.0",
            "manifest_base64": encode(manifest),
            "package_base64": encode(package),
            "signature_base64": encode(signature),
        }
    });

    let (status, operation) = send(
        state.clone(),
        signed_request(&client, Method::POST, "/api/v1/system/updates", body, true),
    )
    .await;

    assert_eq!(status, StatusCode::ACCEPTED, "{operation}");
    wait_for(&observed, "install_runtime_update");
    let release = state.runtime_update_staging_root.join("dev-0.2.0");
    assert_eq!(
        std::fs::read(release.join(spark_privd::update::STAGED_MANIFEST)).unwrap(),
        manifest
    );
    assert_eq!(
        std::fs::read(release.join(spark_privd::update::STAGED_PACKAGE)).unwrap(),
        package
    );
    assert_eq!(
        std::fs::read(release.join(spark_privd::update::STAGED_SIGNATURE)).unwrap(),
        signature
    );

    let connection = state.database.as_ref().unwrap().lock();
    let operation_input: String = connection
        .query_row(
            "SELECT input_json FROM operations WHERE kind = 'system.software_updates'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    let audit: String = connection
        .query_row(
            "SELECT details_json FROM audit_records WHERE action = 'system.software_updates'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    for protected in [encode(manifest), encode(package), encode(signature)] {
        assert!(!operation_input.contains(&protected));
        assert!(!audit.contains(&protected));
    }
    assert!(operation_input.contains("runtime_bundle_supplied"));
    assert!(operation_input.contains("runtime_package_bytes"));
}
