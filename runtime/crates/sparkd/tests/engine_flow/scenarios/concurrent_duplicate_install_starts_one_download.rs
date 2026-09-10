#[tokio::test]
async fn concurrent_duplicate_install_queues_one_operation() {
    let (h, addr, key, device_id) = harness(240 << 30).await;
    let client = reqwest::Client::new();
    let idempotency_key = uuid::Uuid::new_v4().to_string();
    let path = "/api/v1/models/example%2Fnot-installed/install";
    let body = previewed_apply_body(
        &client,
        addr,
        &key,
        &device_id,
        "POST",
        path,
        Some(json!({})),
    )
    .await
    .unwrap()
    .unwrap();
    let first = signed_json_with_idempotency(
        &client,
        addr,
        &key,
        &device_id,
        "POST",
        path,
        Some(body.clone()),
        Some(&idempotency_key),
    );
    let second = signed_json_with_idempotency(
        &client,
        addr,
        &key,
        &device_id,
        "POST",
        path,
        Some(body),
        Some(&idempotency_key),
    );
    let ((first_status, first_body), (second_status, second_body)) = tokio::join!(first, second);

    assert_eq!(first_status, reqwest::StatusCode::ACCEPTED, "{first_body}");
    assert_eq!(
        second_status,
        reqwest::StatusCode::ACCEPTED,
        "{second_body}"
    );
    assert_eq!(first_body, second_body);
    let id = first_body["id"].as_str().unwrap().parse().unwrap();
    let terminal = wait_terminal(&h.state, id, Duration::from_secs(5)).await;
    assert_eq!(terminal["state"], "succeeded", "{terminal}");
    let manifest_reads = h.download_starts.load(Ordering::SeqCst);
    assert!(
        (3..=4).contains(&manifest_reads),
        "preview and worker each read once; concurrent apply validation may read twice: {manifest_reads}"
    );
    let operation_count: i64 = h
        .state
        .database
        .as_ref()
        .unwrap()
        .lock()
        .query_row(
            "SELECT COUNT(*) FROM operations WHERE kind = 'model.install'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(operation_count, 1);
}
