/// Report mock container-runtime availability truthfully within the role-protected Capabilities schema.
#[tokio::test]
async fn capabilities_reports_dev_stub_truthfully_and_is_role_protected() {
    let (h, addr, key, device_id) = harness(240 << 30).await;
    let client = reqwest::Client::new();

    // Protected: no device signature means no capability document.
    let plain = client
        .get(format!("http://{addr}/api/v1/capabilities"))
        .send()
        .await
        .expect("send");
    assert_eq!(plain.status(), reqwest::StatusCode::UNAUTHORIZED);

    let (status, body) = signed_json(
        &client,
        addr,
        &key,
        &device_id,
        "GET",
        "/api/v1/capabilities",
        None,
    )
    .await;
    assert_eq!(status, reqwest::StatusCode::OK, "{body}");
    // Contract-schema truth (Capabilities: api_version + features map).
    assert_eq!(body["api_version"], 1);
    let features = body["features"].as_object().expect("features object");
    assert!(
        features.values().all(|value| value.is_boolean()),
        "every feature is a boolean"
    );
    // The dev/mock backend must never claim a host container runtime.
    assert_eq!(features["container_runtime"], false);
    assert_eq!(features["loopback_only"], true);
    assert_eq!(features["signed_catalogue"], true);
    assert_eq!(features["unverified_import"], false);
    assert_eq!(features["cluster_management"], false);
    assert_eq!(features["cluster_inference"], false);
    assert_eq!(features["fabric_inventory"], true);
    assert_eq!(features["external_cluster_import_preview"], true);
    assert_eq!(features["external_cluster_registration"], false);
    assert_eq!(features["fabric_takeover"], false);
    assert_eq!(body["limits"]["engine_backend"], "mock");
    assert_eq!(body["limits"]["max_active_large_models"], 1);
    assert_eq!(body["limits"]["internal_port_range_start"], 18100);
    assert_eq!(body["limits"]["internal_port_range_end"], 18199);
    let _ = &h;
}
