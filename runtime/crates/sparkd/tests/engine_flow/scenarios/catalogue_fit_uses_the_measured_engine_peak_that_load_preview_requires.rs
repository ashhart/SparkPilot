#[tokio::test]
async fn catalogue_fit_uses_the_measured_engine_peak_that_load_preview_requires() {
    let (h, addr, key, device_id) = harness(150_000_000_000).await;
    let client = reqwest::Client::new();
    let measured_peak = 180_000_000_000_u64;
    sparkd::guard::record_profile_peak(
        &h.state.database.as_ref().unwrap().lock(),
        "example/model-32b",
        "balanced-16k",
        measured_peak,
        &fixture_environment(),
    )
    .unwrap();
    let (status, preview) = signed_json(
        &client,
        addr,
        &key,
        &device_id,
        "POST",
        "/api/v1/inference/load/preview",
        Some(json!({"model_id": "example/model-32b", "profile_id": "balanced-16k"})),
    )
    .await;
    assert_eq!(status, reqwest::StatusCode::OK, "{preview}");
    assert_eq!(preview["evidence"]["required_memory_bytes"], measured_peak);
    assert_eq!(
        preview["evidence"]["memory_admission"],
        "deny_insufficient_memory"
    );
    // Keep checkpoint disk size separate from measured whole-engine memory, including cache and serving overhead.
    assert_eq!(preview["evidence"]["installed_bytes"], 68_719_476_736_u64);
    for path in ["/api/v1/models", "/api/v1/models/example%2Fmodel-32b"] {
        let (status, response) =
            signed_json(&client, addr, &key, &device_id, "GET", path, None).await;
        assert_eq!(status, reqwest::StatusCode::OK, "{response}");
        let model = if path == "/api/v1/models" {
            response["items"]
                .as_array()
                .unwrap()
                .iter()
                .find(|model| model["id"] == "example/model-32b")
                .unwrap()
        } else {
            &response
        };
        assert_eq!(
            model["fit"], "smaller_profile_required",
            "catalogue must agree with measured-memory admission: {model}"
        );
        assert_eq!(
            model["profiles"][0]["expected_peak_bytes"], 101_000_000_000_u64,
            "the signed recipe declaration stays unchanged"
        );
        assert_eq!(model["profiles"][0]["measured_peak_bytes"], measured_peak);
    }
}
