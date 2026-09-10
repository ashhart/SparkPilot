#[tokio::test]
async fn operation_response_keeps_terminal_evidence_from_the_contract() {
    let (state, client) = test_state();
    let operation_id = uuid::Uuid::new_v4();
    let started_at = "2026-08-31T07:00:01Z";
    let completed_at = "2026-08-31T07:00:02Z";
    {
        let connection = state.database.as_ref().expect("operation database").lock();
        connection
            .execute(
                "INSERT INTO operations
                    (id, kind, state, actor_device_id, resource_id, progress, stage,
                     created_at, updated_at, started_at, completed_at, error_code,
                     result_json, cancellable, input_json)
                 VALUES (?1, 'model.install', 'failed', ?2, 'model:test', 0.75,
                         'verifying', '2026-08-31T07:00:00Z', ?4, ?3, ?4,
                         'MODEL_DIGEST_MISMATCH', '{\"verified\":false}', 0, '{}')",
                rusqlite::params![
                    operation_id.to_string(),
                    client.device_id.to_string(),
                    started_at,
                    completed_at,
                ],
            )
            .expect("seed terminal operation");
    }

    let path = format!("/api/v1/operations/{operation_id}");
    let (status, body) = get_json(state, &client, &path).await;

    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["started_at"], started_at);
    assert_eq!(body["completed_at"], completed_at);
    assert_eq!(body["error_code"], "MODEL_DIGEST_MISMATCH");
    assert_eq!(body["result"]["verified"], false);
}
