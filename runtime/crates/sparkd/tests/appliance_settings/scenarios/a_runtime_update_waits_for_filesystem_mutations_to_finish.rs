/// §45.2 step 4: refuse an update while durable work is still mutating the runtime's own files.
#[tokio::test]
async fn a_runtime_update_waits_for_filesystem_mutations_to_finish() {
    for kind in ["model.install", "model.remove", "catalogue.refresh", "model.load"] {
        let (state, client, observed) = test_state("owner");
        let actor = {
            let conn = state.database.as_ref().expect("db").lock();
            conn.query_row("SELECT id FROM devices LIMIT 1", [], |row| {
                row.get::<_, String>(0)
            })
            .map(|id| uuid::Uuid::parse_str(&id).unwrap())
            .expect("a paired device")
        };
        let running = {
            let conn = state.database.as_ref().expect("db").lock();
            let id = state
                .jobs
                .create(&conn, kind, actor, Some("example/model"), "{}")
                .expect("queue the mutation");
            conn.execute(
                "UPDATE operations SET state = 'running' WHERE id = ?1",
                [id.to_string()],
            )
            .unwrap();
            id
        };

        let body = json!({ "system_packages": true, "firmware": false });
        let (status, envelope) = send(
            state.clone(),
            signed_request(&client, Method::POST, "/api/v1/system/updates", body, true),
        )
        .await;
        assert_eq!(
            status,
            StatusCode::CONFLICT,
            "{kind} was running: {envelope}"
        );
        assert_eq!(envelope["error"]["code"], "UPDATE_BLOCKED_BY_OPERATION");
        assert_eq!(
            envelope["error"]["details"]["operation_kind"], kind,
            "the refusal names the work the owner must wait for"
        );
        assert_eq!(
            envelope["error"]["details"]["operation_id"],
            running.to_string()
        );
        assert!(
            observed.lock().unwrap().is_empty(),
            "{kind}: nothing may reach the privileged helper before the refusal"
        );

        // The same request succeeds once the mutation reaches a terminal state.
        {
            let conn = state.database.as_ref().expect("db").lock();
            conn.execute(
                "UPDATE operations SET state = 'succeeded' WHERE id = ?1",
                [running.to_string()],
            )
            .unwrap();
        }
        let (status, envelope) = send(
            state.clone(),
            signed_request(
                &client,
                Method::POST,
                "/api/v1/system/updates",
                json!({ "system_packages": true, "firmware": false }),
                true,
            ),
        )
        .await;
        assert_eq!(status, StatusCode::ACCEPTED, "{kind}: {envelope}");
    }
}
