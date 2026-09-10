#[tokio::test]
async fn events_replay_crosses_fixed_batches_without_skipping() {
    let (state, client) = test_state();
    let total = sparkd::events::REPLAY_BATCH_SIZE * 2 + 3;
    for _ in 0..total {
        emit_public_event(&state, "operation.progress");
    }

    let response = open_events(state, &client, Some("0")).await;
    assert_eq!(response.status(), StatusCode::OK);
    let mut stream = response.into_body().into_data_stream();
    for expected in 1..=total as i64 {
        let event = next_sse_event(&mut stream).await;
        assert_eq!(event["sequence"], expected);
    }
}
