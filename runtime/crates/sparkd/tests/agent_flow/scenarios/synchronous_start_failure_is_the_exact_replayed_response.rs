#[tokio::test]
async fn synchronous_start_failure_is_the_exact_replayed_response() {
    let (h, addr, key, device_id) = harness(vec![]).await;
    let client = reqwest::Client::new();
    let project_id = create_project(&client, addr, &key, &device_id, &h.state, "vanished").await;
    {
        // Retain membership so the test reaches post-admission service failure rather than earlier authorization refusal.
        let connection = h.state.database.as_ref().unwrap().lock();
        connection.execute_batch("PRAGMA foreign_keys=OFF").unwrap();
        connection
            .execute("DELETE FROM projects WHERE id = ?1", [&project_id])
            .unwrap();
        connection.execute_batch("PRAGMA foreign_keys=ON").unwrap();
    }

    let path = format!("/api/v1/projects/{project_id}/agents");
    let body = json!({ "task": "must fail before a worker is spawned" });
    let request_key = uuid::Uuid::new_v4();
    let (first_status, first) = signed_json_with_idempotency(
        &client,
        addr,
        &key,
        &device_id,
        "POST",
        &path,
        Some(body.clone()),
        request_key,
    )
    .await;
    let (replay_status, replay) = signed_json_with_idempotency(
        &client,
        addr,
        &key,
        &device_id,
        "POST",
        &path,
        Some(body),
        request_key,
    )
    .await;
    assert_eq!(first_status, reqwest::StatusCode::INTERNAL_SERVER_ERROR);
    assert_eq!(replay_status, first_status);
    assert_eq!(replay, first);

    let connection = h.state.database.as_ref().unwrap().lock();
    let operations: i64 = connection
        .query_row(
            "SELECT COUNT(*) FROM operations WHERE kind = 'project.agent' AND state = 'failed'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(operations, 1);
}
