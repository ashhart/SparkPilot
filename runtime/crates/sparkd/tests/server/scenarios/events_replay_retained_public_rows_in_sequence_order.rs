#[tokio::test]
async fn events_replay_retained_public_rows_in_sequence_order() {
    let (state, client) = test_state();
    let first = emit_public_event(&state, "operation.created");

    {
        let database = state.database.as_ref().unwrap();
        let conn = database.lock();
        conn.execute(
            "INSERT INTO events
                (event_id, event_type, severity, occurred_at, node_id,
                 visibility_json, payload_json)
             VALUES (?1, 'operation.private', 'info', ?2, ?3, ?4, '{}')",
            rusqlite::params![
                uuid::Uuid::new_v4().to_string(),
                time::OffsetDateTime::now_utc()
                    .format(&time::format_description::well_known::Rfc3339)
                    .unwrap(),
                state.identity.node_id().to_string(),
                r#"{"device_ids":["another-device"]}"#,
            ],
        )
        .unwrap();
    }
    let third = emit_public_event(&state, "operation.progress");
    let fourth = emit_public_event(&state, "operation.completed");

    let response = open_events(state, &client, Some(&first.to_string())).await;
    assert_eq!(response.status(), StatusCode::OK);
    assert_eq!(response.headers()["content-type"], "text/event-stream");
    let mut stream = response.into_body().into_data_stream();
    let progress = next_sse_event(&mut stream).await;
    let completed = next_sse_event(&mut stream).await;

    assert_eq!(progress["sequence"], third);
    assert_eq!(progress["type"], "operation.progress");
    assert_eq!(completed["sequence"], fourth);
    assert_eq!(completed["type"], "operation.completed");
}
