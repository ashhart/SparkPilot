#[tokio::test]
async fn catalogue_replacement_fit_uses_the_same_baseline_as_preview() {
    let (h, addr, key, device_id) = harness(240_000_000_000).await;
    let client = reqwest::Client::new();
    let operation: uuid::Uuid = load_model(&client, addr, &key, &device_id, None).await["id"]
        .as_str()
        .unwrap()
        .parse()
        .unwrap();
    assert_eq!(
        wait_terminal(&h.state, operation, Duration::from_secs(10)).await["state"],
        "succeeded"
    );
    h.available.store(60_000_000_000, Ordering::Relaxed);
    sparkd::guard::record_profile_peak(
        &h.state.database.as_ref().unwrap().lock(),
        "example/model-32b",
        "balanced-16k",
        180_000_000_000,
        &fixture_environment(),
    )
    .unwrap();
    let (status, preview) = signed_json(
        &client, addr, &key, &device_id, "POST", "/api/v1/inference/load/preview",
        Some(json!({"model_id": "example/model-32b", "profile_id": "balanced-16k", "replace_active": true})),
    ).await;
    assert_eq!(status, reqwest::StatusCode::OK, "{preview}");
    assert_eq!(preview["evidence"]["memory_admission"], "allow");
    assert_eq!(
        preview["evidence"]["available_memory_bytes"],
        240_000_000_000_u64
    );
    let (status, response) = signed_json(
        &client,
        addr,
        &key,
        &device_id,
        "GET",
        "/api/v1/models",
        None,
    )
    .await;
    assert_eq!(status, reqwest::StatusCode::OK, "{response}");
    let model = response["items"]
        .as_array()
        .unwrap()
        .iter()
        .find(|model| model["id"] == "example/model-32b")
        .unwrap();
    assert_eq!(
        model["fit"], "fits_after_unload",
        "the catalogue must not cap the running engine at its smaller recipe declaration"
    );
}
