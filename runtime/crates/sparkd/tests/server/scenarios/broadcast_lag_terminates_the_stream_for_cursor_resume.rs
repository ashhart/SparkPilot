#[tokio::test]
async fn broadcast_lag_terminates_the_stream_for_cursor_resume() {
    let (state, client) = test_state();
    let response = open_events(state.clone(), &client, None).await;
    assert_eq!(response.status(), StatusCode::OK);
    let mut stream = response.into_body().into_data_stream();

    {
        let database = state.database.as_ref().unwrap();
        let conn = database.lock();
        for index in 0..=sparkd::events::FANOUT_CAPACITY {
            state.events.emit(
                Some(&conn),
                &state.identity.node_id().to_string(),
                None,
                "operation.progress",
                "info",
                json!({ "index": index }),
            );
        }
    }

    let end = tokio::time::timeout(Duration::from_secs(1), stream.next())
        .await
        .expect("lagged stream did not terminate");
    assert!(end.is_none(), "lagged stream emitted another frame");
}
