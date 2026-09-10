#[tokio::test]
async fn fixed_target_history_keeps_safe_admission_refusals_and_completed_attempts() {
    let (h, addr, key, device_id) = harness(240 << 30).await;
    h.state.telemetry_consent.write().functional = true;
    let client = reqwest::Client::new();
    for model in [
        "example/model-32b",
        "private prompt accidentally placed in model field",
    ] {
        let (status, _) = signed_json(&client,addr,&key,&device_id,"POST","/v1/chat/completions",Some(json!({"model":model,"messages":[{"role":"user","content":"private request text"}],"stream":false}))).await;
        assert!(!status.is_success());
    }
    let (status, history) = signed_json(
        &client,
        addr,
        &key,
        &device_id,
        "GET",
        "/api/v1/inference/requests",
        None,
    )
    .await;
    assert_eq!(status, reqwest::StatusCode::OK, "{history}");
    assert_eq!(history["records"].as_array().unwrap().len(), 1);
    assert_eq!(history["records"][0]["outcome"], "failed");
    assert_eq!(history["records"][0]["model_id"], "example/model-32b");
    assert!(history["records"][0]["provenance"].is_null());

    let operation_id = uuid::Uuid::parse_str(
        load_model(&client, addr, &key, &device_id, None).await["id"]
            .as_str()
            .unwrap(),
    )
    .unwrap();
    assert_eq!(
        wait_terminal(&h.state, operation_id, Duration::from_secs(10)).await["state"],
        "succeeded"
    );
    let (status,_) = signed_json(&client,addr,&key,&device_id,"POST","/v1/chat/completions",Some(json!({"model":"example/model-32b","messages":[{"role":"user","content":"private request text"}],"max_tokens":16,"stream":false}))).await;
    assert_eq!(status, reqwest::StatusCode::OK);
    let (status, history) = signed_json(
        &client,
        addr,
        &key,
        &device_id,
        "GET",
        "/api/v1/inference/requests?outcome=succeeded",
        None,
    )
    .await;
    assert_eq!(status, reqwest::StatusCode::OK, "{history}");
    let rows = history["records"].as_array().unwrap();
    assert_eq!(rows.len(), 1);
    assert_eq!(rows[0]["profile_id"], "balanced-16k");
    assert!(rows[0]["prompt_tokens"].is_number());
    assert!(
        rows[0]["first_frame_ms"].is_null(),
        "buffered response must not invent first-token time"
    );
    assert_eq!(
        rows[0]["provenance"]["verification"],
        "admitted_recipe_only"
    );
    assert_eq!(
        rows[0]["provenance"]["recipe_digest"]
            .as_str()
            .unwrap()
            .len(),
        64
    );
    let (preview_status, preview) = signed_json(&client,addr,&key,&device_id,"POST","/api/v1/inference/load/preview",Some(json!({"model_id":"example/model-32b","profile_id":"balanced-16k","replace_active":false}))).await;
    assert_eq!(preview_status, reqwest::StatusCode::OK, "{preview}");
    assert_eq!(
        rows[0]["provenance"]["recipe_digest"],
        preview["evidence"]["active_engine"]["recipe_digest"],
        "history and signed preview must bind identical recipe bytes"
    );

    assert!(!history.to_string().contains("private request text"));
    assert!(!history.to_string().contains("127.0.0.1"));
    let (status, clear) = signed_json(
        &client,
        addr,
        &key,
        &device_id,
        "DELETE",
        "/api/v1/inference/requests",
        None,
    )
    .await;
    assert_eq!(status, reqwest::StatusCode::OK, "{clear}");
    assert_eq!(clear["cleared"], 2);
}
