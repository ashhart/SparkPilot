#[tokio::test]
async fn replacement_requires_explicit_request() {
    let (h, addr, key, device_id) = harness(240 << 30).await;
    let client = reqwest::Client::new();

    let operation_id: uuid::Uuid = load_model(&client, addr, &key, &device_id, None).await["id"]
        .as_str()
        .and_then(|s| uuid::Uuid::parse_str(s).ok())
        .expect("load operation id");
    wait_terminal(&h.state, operation_id, Duration::from_secs(10)).await;

    // Never unload suppresses the idle timer, but must not pin a model against replacement.
    h.state.database.as_ref().unwrap().lock().execute(
        "INSERT INTO model_idle_policies(model_id, profile_id, idle_policy, updated_at, updated_by_device_id) VALUES ('example/model-32b', 'balanced-16k', 'keep_ready', '2026-09-06T00:00:00Z', ?1)",
        rusqlite::params![device_id.to_string()],
    ).unwrap();
    h.engine.refresh_idle_policy("example/model-32b", "balanced-16k");

    let replacement_request = json!({
        "model_id": "example/model-32b",
        "profile_id": "balanced-16k",
    });
    let (preview_status, preview) = signed_json_with_idempotency(
        &client,
        addr,
        &key,
        &device_id,
        "POST",
        "/api/v1/inference/load/preview",
        Some(replacement_request.clone()),
        Some(&uuid::Uuid::new_v4().to_string()),
    )
    .await;
    assert_eq!(preview_status, reqwest::StatusCode::OK, "{preview}");
    assert_eq!(preview["action"], "replace");
    assert_eq!(
        preview["consequences"]["model_to_stop"],
        "example/model-32b"
    );
    assert_eq!(
        preview["evidence"]["active_engine"]["profile_id"],
        "balanced-16k"
    );
    assert_eq!(
        preview["evidence"]["active_engine"]["recipe_digest"],
        preview["recipe"]["recipe_digest"]
    );
    assert_eq!(preview["blockers"][0]["code"], "ENGINE_ACTIVE");

    // A second load of the same model without replace_active is refused.
    let (status, body) = signed_json(
        &client,
        addr,
        &key,
        &device_id,
        "POST",
        "/api/v1/inference/load",
        Some(replacement_request),
    )
    .await;
    assert_eq!(status, reqwest::StatusCode::CONFLICT, "{body}");
    assert_eq!(body["error"]["code"], "ENGINE_ACTIVE", "{body}");

    // With replace_active=true the transition is accepted and completes.
    let operation_id: uuid::Uuid =
        load_model(&client, addr, &key, &device_id, Some(true)).await["id"]
            .as_str()
            .and_then(|s| uuid::Uuid::parse_str(s).ok())
            .expect("replace operation id");
    let terminal = wait_terminal(&h.state, operation_id, Duration::from_secs(10)).await;
    assert_eq!(terminal["state"], "succeeded", "{terminal}");
    let (_, active) = signed_json(
        &client,
        addr,
        &key,
        &device_id,
        "GET",
        "/api/v1/inference/active",
        None,
    )
    .await;
    assert_eq!(active["state"].as_str().unwrap_or(""), "idle", "{active}");
}
