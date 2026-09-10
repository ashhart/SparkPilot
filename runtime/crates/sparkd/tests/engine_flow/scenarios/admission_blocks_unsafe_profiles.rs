#[tokio::test]
async fn admission_blocks_unsafe_profiles() {
    let (h, addr, key, device_id) = harness(240 << 30).await;
    let client = reqwest::Client::new();

    // Mark the profile unsafe as the guard does after a pressure failure.
    {
        let conn = h.state.database.as_ref().expect("db").lock();
        sparkd::guard::mark_profile_unsafe(
            &conn,
            "example/model-32b",
            "balanced-16k",
            "memory_guard_emergency",
        )
        .expect("mark unsafe");
    }

    let (status, body) = signed_json(
        &client,
        addr,
        &key,
        &device_id,
        "POST",
        "/api/v1/inference/load",
        Some(json!({ "model_id": "example/model-32b", "profile_id": "balanced-16k" })),
    )
    .await;
    assert_eq!(status, reqwest::StatusCode::CONFLICT, "{body}");
    assert_eq!(body["error"]["code"], "MODEL_PROFILE_UNSAFE", "{body}");
}
