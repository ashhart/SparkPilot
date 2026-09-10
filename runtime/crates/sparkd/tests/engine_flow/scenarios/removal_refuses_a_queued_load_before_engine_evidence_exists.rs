#[tokio::test]
async fn removal_refuses_a_queued_load_before_engine_evidence_exists() {
    let (h, addr, key, device_id) = harness(240 << 30).await;
    let client = reqwest::Client::new();
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
    assert_eq!(preview["blockers"], json!([]), "{preview}");

    {
        let connection = h.state.database.as_ref().unwrap().lock();
        h.state
            .jobs
            .create(
                &connection,
                "model.load",
                device_id,
                Some("example/model-32b"),
                r#"{"model":"example/model-32b","profile":"balanced-16k"}"#,
            )
            .unwrap();
    }

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
    assert_eq!(remove["error"]["code"], "PREVIEW_STALE");
    assert!(
        sparkd::store::model_row(
            &h.state.database.as_ref().unwrap().lock(),
            "example/model-32b"
        )
        .unwrap()
        .is_some()
    );
    assert!(h.engine.view().is_none());

    let (blocked_status, blocked) = signed_json_with_idempotency(
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
    assert_eq!(blocked_status, reqwest::StatusCode::OK, "{blocked}");
    assert!(
        blocked["blockers"]
            .as_array()
            .unwrap()
            .iter()
            .any(|message| message["code"] == "MODEL_LOAD_IN_PROGRESS"),
        "{blocked}"
    );
}
