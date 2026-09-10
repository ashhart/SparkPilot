#[tokio::test]
async fn completed_engine_operation_event_is_durable_and_replayable() {
    let (h, addr, key, device_id) = harness(240 << 30).await;
    let client = reqwest::Client::new();

    let operation_id: uuid::Uuid = load_model(&client, addr, &key, &device_id, None).await["id"]
        .as_str()
        .and_then(|id| uuid::Uuid::parse_str(id).ok())
        .expect("load operation id");
    let terminal = wait_terminal(&h.state, operation_id, Duration::from_secs(10)).await;
    assert_eq!(terminal["state"], "succeeded", "{terminal}");

    let sequence: i64 = {
        let conn = h.state.database.as_ref().unwrap().lock();
        conn.query_row(
            "SELECT sequence FROM events
             WHERE operation_id = ?1 AND event_type = 'model.ready'",
            [operation_id.to_string()],
            |row| row.get(0),
        )
        .expect("durable model.ready event")
    };
    assert!(sequence >= 1);

    let response = signed_event_stream(&client, addr, &key, &device_id, sequence - 1).await;
    assert_eq!(response.status(), reqwest::StatusCode::OK);
    let mut stream = response.bytes_stream();
    let bytes = tokio::time::timeout(Duration::from_secs(1), async {
        futures::StreamExt::next(&mut stream).await
    })
    .await
    .expect("replay timeout")
    .expect("replayed event")
    .expect("replay body");
    let frame = String::from_utf8(bytes.to_vec()).expect("SSE frame UTF-8");
    let data = frame
        .lines()
        .find_map(|line| line.strip_prefix("data: "))
        .expect("SSE data line");
    let event: Value = serde_json::from_str(data).expect("event envelope");
    assert_eq!(event["sequence"], sequence);
    assert_eq!(event["operation_id"], operation_id.to_string());
    assert_eq!(event["type"], "model.ready");
}
