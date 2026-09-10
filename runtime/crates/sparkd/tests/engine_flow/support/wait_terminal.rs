/// Poll the durable operation until terminal; returns the operation row.
async fn wait_terminal(state: &AppState, operation_id: uuid::Uuid, timeout: Duration) -> Value {
    let deadline = std::time::Instant::now() + timeout;
    loop {
        let row = {
            let conn = state.database.as_ref().expect("db").lock();
            state
                .jobs
                .get(&conn, operation_id)
                .expect("operation get")
                .expect("operation present")
        };
        let row_value = serde_json::to_value(&row).unwrap();
        let state_name = row_value
            .get("state")
            .and_then(Value::as_str)
            .unwrap_or("running");
        if state_name == "succeeded" || state_name == "failed" {
            return row_value;
        }
        assert!(
            std::time::Instant::now() < deadline,
            "operation did not finish: {row_value}"
        );
        tokio::time::sleep(Duration::from_millis(15)).await;
    }
}
