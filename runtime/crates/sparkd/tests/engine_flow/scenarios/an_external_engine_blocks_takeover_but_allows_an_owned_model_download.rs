#[tokio::test]
async fn an_external_engine_blocks_takeover_but_allows_an_owned_model_download() {
    let (h, addr, key, device_id) = harness_with_external_engine(240 << 30).await;
    let client = reqwest::Client::new();
    let request = json!({
        "model_id": "example/model-32b",
        "profile_id": "balanced-16k",
        // replace_active authorizes only runtime-owned replacements, never takeover of external workloads.
        "replace_active": true,
    });

    let (preview_status, preview) = signed_json_with_idempotency(
        &client,
        addr,
        &key,
        &device_id,
        "POST",
        "/api/v1/inference/load/preview",
        Some(request.clone()),
        Some(&uuid::Uuid::new_v4().to_string()),
    )
    .await;
    assert_eq!(preview_status, reqwest::StatusCode::OK, "{preview}");
    assert!(preview["blockers"].as_array().is_some_and(|blockers| {
        blockers
            .iter()
            .any(|blocker| blocker["code"] == "EXTERNAL_ENGINE_ACTIVE")
    }));

    let mut apply = request;
    apply.as_object_mut().unwrap().insert(
        "accepted_preview_digest".into(),
        preview["preview_digest"].clone(),
    );
    let (apply_status, apply_response) = signed_json_with_idempotency(
        &client,
        addr,
        &key,
        &device_id,
        "POST",
        "/api/v1/inference/load",
        Some(apply),
        Some(&uuid::Uuid::new_v4().to_string()),
    )
    .await;
    assert_eq!(
        apply_status,
        reqwest::StatusCode::CONFLICT,
        "{apply_response}"
    );
    assert_eq!(apply_response["error"]["code"], "EXTERNAL_ENGINE_ACTIVE");
    assert_eq!(
        h.backend.launches(),
        0,
        "external engine triggered a launch"
    );
    let install_path = "/api/v1/models/example%2Fnot-installed/install";
    let (install_preview_status, install_preview) = signed_json_with_idempotency(
        &client,
        addr,
        &key,
        &device_id,
        "POST",
        &format!("{install_path}/preview"),
        Some(json!({})),
        Some(&uuid::Uuid::new_v4().to_string()),
    )
    .await;
    assert_eq!(install_preview_status, reqwest::StatusCode::OK);
    assert_eq!(install_preview["blockers"], json!([]));
    let (install_status, install_response) = signed_json_with_idempotency(
        &client,
        addr,
        &key,
        &device_id,
        "POST",
        install_path,
        Some(json!({
            "accepted_preview_digest": install_preview["preview_digest"],
        })),
        Some(&uuid::Uuid::new_v4().to_string()),
    )
    .await;
    assert_eq!(install_status, reqwest::StatusCode::ACCEPTED);
    let install_id = install_response["id"]
        .as_str()
        .and_then(|id| uuid::Uuid::parse_str(id).ok())
        .expect("model install operation id");
    let installed = wait_terminal(&h.state, install_id, Duration::from_secs(10)).await;
    assert_eq!(installed["state"], "succeeded", "{installed}");
    assert!(h.download_starts.load(Ordering::SeqCst) > 0);
    assert_eq!(h.backend.launches(), 0, "download launched an engine");
    assert_eq!(
        h.privileged_operations
            .as_ref()
            .expect("privileged observation log")
            .lock()
            .expect("privileged observation log")
            .as_slice(),
        [
            "inventory_workloads",
            "inventory_workloads",
            "ensure_engine_image"
        ],
        "the download prepares only its signed pinned engine image and never takes over the external engine"
    );
    let operation_count: i64 = h
        .state
        .database
        .as_ref()
        .expect("db")
        .lock()
        .query_row("SELECT COUNT(*) FROM operations", [], |row| row.get(0))
        .expect("operation count");
    assert_eq!(
        operation_count, 1,
        "only the owned model download was recorded"
    );
}

#[tokio::test]
async fn a_custom_cluster_image_cannot_be_treated_as_an_idle_spark() {
    let observed = ObservedWorkloads {
        containers: vec![ObservedContainer {
            id: "f".repeat(64),
            name: Some("deepseek-v4-flash-vllm-dspark-1".into()),
            state: "running".into(),
            image: Some("ghcr.io/anemll/dspark-vllm-gx10:0.1.1".into()),
            ports: vec![],
        }],
        truncated: false,
        unreadable_lines: 0,
    };
    let (h, addr, key, device_id) = harness_with_policy(
        240 << 30,
        system_clock(),
        Duration::from_secs(2),
        false,
        Some(observed),
    ).await;
    let client = reqwest::Client::new();
    let mut request = json!({
        "model_id": "example/model-32b",
        "profile_id": "balanced-16k",
        "replace_active": true,
    });
    let (status, preview) = signed_json_with_idempotency(
        &client, addr, &key, &device_id, "POST", "/api/v1/inference/load/preview",
        Some(request.clone()), Some(&uuid::Uuid::new_v4().to_string()),
    ).await;
    assert_eq!(status, reqwest::StatusCode::OK, "{preview}");
    assert!(preview["blockers"].as_array().is_some_and(|items| items.iter()
        .any(|item| item["code"] == "EXTERNAL_ENGINE_STATE_UNKNOWN")), "{preview}");
    request["accepted_preview_digest"] = preview["preview_digest"].clone();
    let (status, response) = signed_json_with_idempotency(
        &client, addr, &key, &device_id, "POST", "/api/v1/inference/load",
        Some(request), Some(&uuid::Uuid::new_v4().to_string()),
    ).await;
    assert_eq!(status, reqwest::StatusCode::CONFLICT, "{response}");
    assert_eq!(response["error"]["code"], "EXTERNAL_ENGINE_STATE_UNKNOWN");
    assert_eq!(h.backend.launches(), 0);
    assert_eq!(h.privileged_operations.as_ref().unwrap().lock().unwrap().as_slice(),
        ["inventory_workloads", "inventory_workloads"]);
}
