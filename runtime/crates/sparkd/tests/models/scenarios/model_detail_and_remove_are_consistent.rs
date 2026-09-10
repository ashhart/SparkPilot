#[tokio::test]
async fn model_detail_and_remove_are_consistent() {
    let peer = full_peer(false);
    std::fs::create_dir_all(&peer.state.storage.downloads).unwrap();
    let retained_file = peer.state.storage.downloads.join("shared-content");
    std::fs::write(&retained_file, b"retained").unwrap();
    sparkd::store::mark_model_installed(
        &peer.state.database.as_ref().unwrap().lock(),
        "example/model-32b",
        4096,
    )
    .unwrap();
    let (status, detail) = get(&peer, "/api/v1/models/example%2Fmodel-32b").await;
    assert_eq!(status, StatusCode::OK, "detail: {:?}", detail);
    // Path contains '/'; percent-encoded requests are decoded by the router.
    let detail = detail.unwrap();
    assert_eq!(detail["id"], "example/model-32b");

    let key = uuid::Uuid::new_v4();
    let (preview_status, preview) = send_with_key(
        &peer,
        Method::POST,
        "/api/v1/models/example%2Fmodel-32b/remove/preview",
        Value::Null,
        key,
    )
    .await;
    assert_eq!(preview_status, StatusCode::OK, "{preview:?}");
    let preview = preview.unwrap();
    assert_eq!(preview["consequences"]["files_removed"], json!([]));
    assert_eq!(preview["evidence"]["removable_bytes"], 0);
    assert_eq!(preview["warnings"][0]["code"], "MODEL_FILES_RETAINED");
    let apply = json!({
        "accepted_preview_digest": preview["preview_digest"].as_str().unwrap()
    });
    let (status, operation) = send_with_key(
        &peer,
        Method::DELETE,
        "/api/v1/models/example%2Fmodel-32b",
        apply.clone(),
        key,
    )
    .await;
    assert_eq!(status, StatusCode::ACCEPTED);
    let operation = operation.unwrap();
    assert_eq!(operation["kind"], "model.remove");
    assert_eq!(operation["state"], "succeeded");
    let operation_id = operation["id"].as_str().unwrap().to_owned();
    let (replay_status, replay) = send_with_key(
        &peer,
        Method::DELETE,
        "/api/v1/models/example%2Fmodel-32b",
        apply,
        key,
    )
    .await;
    assert_eq!(replay_status, StatusCode::ACCEPTED);
    assert_eq!(replay, Some(operation));
    // Gone afterwards.
    let (status, _) = get(&peer, "/api/v1/models/example%2Fmodel-32b").await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    assert!(
        retained_file.exists(),
        "inventory removal must not claim or delete shared content"
    );
    let audit = {
        let connection = peer.state.database.as_ref().unwrap().lock();
        let mut statement = connection
            .prepare(
                "SELECT action, result, resource, operation_id, details_json
                   FROM audit_records ORDER BY sequence",
            )
            .unwrap();
        statement
            .query_map([], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, String>(2)?,
                    row.get::<_, Option<String>>(3)?,
                    row.get::<_, String>(4)?,
                ))
            })
            .unwrap()
            .collect::<Result<Vec<_>, _>>()
            .unwrap()
    };
    assert_eq!(audit.len(), 3);
    assert_eq!(audit[0].0, "model.remove.preview");
    assert_eq!(audit[0].1, "accepted");
    assert_eq!(audit[1].0, "model.remove");
    assert_eq!(audit[1].1, "accepted");
    assert_eq!(audit[1].2, "model/example/model-32b");
    assert_eq!(audit[1].3.as_deref(), Some(operation_id.as_str()));
    assert_eq!(audit[1].4, r#"{"shared_files_retained":true}"#);
    assert_eq!(audit[2].0, "model.remove");
    assert_eq!(audit[2].1, "succeeded");
    assert_eq!(audit[2].2, "model/example/model-32b");
    assert_eq!(audit[2].3.as_deref(), Some(operation_id.as_str()));
    assert_eq!(audit[2].4, "{}");
}
