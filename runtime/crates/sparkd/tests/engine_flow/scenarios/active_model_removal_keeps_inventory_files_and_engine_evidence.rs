#[tokio::test]
async fn active_model_removal_keeps_inventory_files_and_engine_evidence() {
    let (h, addr, key, device_id) = harness(240 << 30).await;
    let client = reqwest::Client::new();
    let load_operation_id: uuid::Uuid =
        load_model(&client, addr, &key, &device_id, None).await["id"]
            .as_str()
            .and_then(|value| uuid::Uuid::parse_str(value).ok())
            .unwrap();
    wait_terminal(&h.state, load_operation_id, Duration::from_secs(10)).await;
    std::fs::create_dir_all(&h.state.storage.models).unwrap();
    let retained_file = h.state.storage.models.join("retained-model-byte");
    std::fs::write(&retained_file, b"retained").unwrap();

    let preview_path = "/api/v1/models/example%2Fmodel-32b/remove/preview";
    let (preview_status, preview) = signed_json_with_idempotency(
        &client,
        addr,
        &key,
        &device_id,
        "POST",
        preview_path,
        None,
        Some(&uuid::Uuid::new_v4().to_string()),
    )
    .await;
    assert_eq!(preview_status, reqwest::StatusCode::OK, "{preview}");
    assert!(
        preview["blockers"]
            .as_array()
            .unwrap()
            .iter()
            .any(|message| message["code"] == "MODEL_ACTIVE"),
        "{preview}"
    );
    assert_eq!(preview["consequences"]["files_removed"], json!([]));
    assert_eq!(preview["evidence"]["removable_bytes"], 0);

    let (remove_status, remove) = signed_json_with_idempotency(
        &client,
        addr,
        &key,
        &device_id,
        "DELETE",
        "/api/v1/models/example%2Fmodel-32b",
        Some(json!({
            "accepted_preview_digest": preview["preview_digest"],
        })),
        Some(&uuid::Uuid::new_v4().to_string()),
    )
    .await;
    assert_eq!(remove_status, reqwest::StatusCode::CONFLICT, "{remove}");
    assert_eq!(remove["error"]["code"], "MODEL_ACTIVE");
    assert_eq!(
        sparkd::store::model_row(
            &h.state.database.as_ref().unwrap().lock(),
            "example/model-32b"
        )
        .unwrap()
        .unwrap()
        .install_state,
        "installed"
    );
    assert!(retained_file.exists());
    assert_eq!(
        h.engine.view().unwrap().model_id,
        "example/model-32b",
        "the refusal must not disturb active-engine evidence"
    );
}
