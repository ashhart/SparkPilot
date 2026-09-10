#[tokio::test]
async fn duplicate_operation_cancel_replays_the_original_transition() {
    let (h, addr, key, device_id) = harness(240 << 30).await;
    let client = reqwest::Client::new();
    let operation_id = {
        let conn = h.state.database.as_ref().expect("db").lock();
        h.state
            .jobs
            .create(&conn, "test.wait", device_id, None, "{}")
            .unwrap()
    };
    let path = format!("/api/v1/operations/{operation_id}/cancel");
    let idempotency_key = uuid::Uuid::new_v4().to_string();

    let (first_status, first_body) = signed_json_with_idempotency(
        &client,
        addr,
        &key,
        &device_id,
        "POST",
        &path,
        None,
        Some(&idempotency_key),
    )
    .await;
    let (replay_status, replay_body) = signed_json_with_idempotency(
        &client,
        addr,
        &key,
        &device_id,
        "POST",
        &path,
        None,
        Some(&idempotency_key),
    )
    .await;

    assert_eq!(first_status, reqwest::StatusCode::ACCEPTED, "{first_body}");
    assert_eq!(
        replay_status,
        reqwest::StatusCode::ACCEPTED,
        "{replay_body}"
    );
    assert_eq!(replay_body, first_body);
    assert_eq!(first_body["state"], "cancelling");
}
