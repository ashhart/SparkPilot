#[tokio::test]
async fn events_signed_live_handoff_delivers_each_event_once() {
    let (state, client) = test_state();
    let first = emit_public_event(&state, "operation.created");
    let response = open_events(state.clone(), &client, Some(&first.to_string())).await;
    assert_eq!(response.status(), StatusCode::OK);
    let mut stream = response.into_body().into_data_stream();

    let progress_sequence = emit_public_event(&state, "operation.progress");
    let live_sequence = emit_public_event(&state, "operation.completed");
    let progress = next_sse_event(&mut stream).await;
    let live = next_sse_event(&mut stream).await;
    assert_eq!(progress["sequence"], progress_sequence);
    assert_eq!(progress["type"], "operation.progress");
    assert_eq!(live["sequence"], live_sequence);
    assert_eq!(live["type"], "operation.completed");
}
