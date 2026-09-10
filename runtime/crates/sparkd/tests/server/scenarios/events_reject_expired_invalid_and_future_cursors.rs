#[tokio::test]
async fn events_reject_expired_invalid_and_future_cursors() {
    let (state, client) = test_state();
    emit_public_event(&state, "operation.created");
    emit_public_event(&state, "operation.progress");
    let latest = emit_public_event(&state, "operation.completed");
    {
        let database = state.database.as_ref().unwrap();
        let conn = database.lock();
        conn.execute("DELETE FROM events WHERE sequence < ?1", [latest])
            .unwrap();
    }

    let expired = open_events(state.clone(), &client, Some("0")).await;
    assert_eq!(expired.status(), StatusCode::CONFLICT);
    let expired = response_json(expired).await;
    assert_eq!(expired["error"]["code"], "EVENT_CURSOR_EXPIRED");
    assert!(expired["error"]["request_id"].is_string());

    for invalid in ["-1", "not-a-sequence", "9223372036854775808"] {
        let response = open_events(state.clone(), &client, Some(invalid)).await;
        assert_eq!(response.status(), StatusCode::BAD_REQUEST, "{invalid}");
        let body = response_json(response).await;
        assert_eq!(body["error"]["code"], "INVALID_REQUEST", "{body}");
        assert!(body["error"]["request_id"].is_string());
    }

    let future = (latest + 1).to_string();
    let response = open_events(state, &client, Some(&future)).await;
    assert_eq!(response.status(), StatusCode::BAD_REQUEST);
    let body = response_json(response).await;
    assert_eq!(body["error"]["code"], "INVALID_REQUEST");
}
