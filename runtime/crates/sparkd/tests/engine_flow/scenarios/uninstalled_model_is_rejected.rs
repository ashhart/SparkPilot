#[tokio::test]
async fn uninstalled_model_is_rejected() {
    let (h, addr, key, device_id) = harness(240 << 30).await;
    let client = reqwest::Client::new();

    // Refuse catalogue-only uninstalled models before any engine work.
    let (status, body) = signed_json(
        &client,
        addr,
        &key,
        &device_id,
        "POST",
        "/api/v1/inference/load",
        Some(json!({ "model_id": "example/not-installed", "profile_id": "balanced-16k" })),
    )
    .await;
    assert_eq!(status, reqwest::StatusCode::CONFLICT, "{body}");
    assert_eq!(body["error"]["code"], "MODEL_NOT_INSTALLED", "{body}");
    let audit: (String, String, String) = h
        .state
        .database
        .as_ref()
        .unwrap()
        .lock()
        .query_row(
            "SELECT action, result, details_json FROM audit_records ORDER BY sequence DESC LIMIT 1",
            [],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
        )
        .unwrap();
    assert_eq!(audit.0, "model.load");
    assert_eq!(audit.1, "refused");
    assert_eq!(
        serde_json::from_str::<Value>(&audit.2).unwrap()["reason_code"],
        "MODEL_NOT_INSTALLED"
    );
}
