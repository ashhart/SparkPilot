#[tokio::test]
async fn sequence_zero_is_skipped_without_closing_a_healthy_stream() {
    let (state, client) = test_state();
    let response = open_events(state.clone(), &client, None).await;
    assert_eq!(response.status(), StatusCode::OK);
    let mut stream = response.into_body().into_data_stream();

    state.events.emit(
        None,
        &state.identity.node_id().to_string(),
        None,
        "operation.non_durable",
        "warning",
        json!({}),
    );
    let durable_sequence = emit_public_event(&state, "operation.created");
    let durable = next_sse_event(&mut stream).await;
    assert_eq!(durable["sequence"], durable_sequence);
    assert_eq!(durable["type"], "operation.created");
}
