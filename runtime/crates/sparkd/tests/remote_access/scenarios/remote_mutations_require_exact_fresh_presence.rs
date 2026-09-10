#[tokio::test]
async fn remote_mutations_require_exact_fresh_presence() {
    let (state, client, database, _guard) =
        test_state("owner");

    let body = preview_enable_body(&state, &client, "private_overlay", None).await;
    let (status, value) = send(
        state.clone(),
        signed_request_with_options(
            &client,
            "POST",
            "/api/v1/remote/enable",
            Some(&body),
            vec![],
            uuid::Uuid::new_v4(),
            None,
        ),
    )
    .await;
    assert_eq!(status, StatusCode::FORBIDDEN);
    assert_eq!(value["error"]["code"], "USER_PRESENCE_REQUIRED");

    let body = preview_enable_body(&state, &client, "private_overlay", None).await;
    let (status, value) = send(
        state.clone(),
        signed_request_with_options(
            &client,
            "POST",
            "/api/v1/remote/enable",
            Some(&body),
            vec![],
            uuid::Uuid::new_v4(),
            Some("/api/v1/remote/disable"),
        ),
    )
    .await;
    assert_eq!(status, StatusCode::FORBIDDEN);
    assert_eq!(value["error"]["code"], "USER_PRESENCE_INVALID");

    let body = preview_disable_body(&state, &client).await;
    let (status, value) = send(
        state.clone(),
        signed_request_with_options(
            &client,
            "POST",
            "/api/v1/remote/disable",
            Some(&body),
            vec![],
            uuid::Uuid::new_v4(),
            None,
        ),
    )
    .await;
    assert_eq!(status, StatusCode::FORBIDDEN);
    assert_eq!(value["error"]["code"], "USER_PRESENCE_REQUIRED");

    database
        .lock()
        .execute(
            "UPDATE devices
                SET presence_public_key_spki = NULL,
                    presence_public_key_fingerprint = NULL
              WHERE id = ?1",
            [client.device_id.to_string()],
        )
        .unwrap();
    let body = preview_enable_body(&state, &client, "private_overlay", None).await;
    let (status, value) = send(
        state,
        signed_request_with_options(
            &client,
            "POST",
            "/api/v1/remote/enable",
            Some(&body),
            vec![],
            uuid::Uuid::new_v4(),
            Some("/api/v1/remote/enable"),
        ),
    )
    .await;
    assert_eq!(status, StatusCode::FORBIDDEN);
    assert_eq!(value["error"]["code"], "USER_PRESENCE_NOT_REGISTERED");

    let refusals: Vec<(String, String)> = {
        let connection = database.lock();
        let mut statement = connection
            .prepare(
                "SELECT action, details_json FROM audit_records WHERE result = 'refused' ORDER BY sequence",
            )
            .unwrap();
        statement
            .query_map([], |row| Ok((row.get(0)?, row.get(1)?)))
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap()
    };
    assert_eq!(refusals.len(), 4);
    assert_eq!(refusals[0].0, "remote.enable");
    assert_eq!(refusals[1].0, "remote.enable");
    assert_eq!(refusals[2].0, "remote.disable");
    assert_eq!(refusals[3].0, "remote.enable");
    assert!(refusals[0].1.contains("USER_PRESENCE_REQUIRED"));
    assert!(refusals[1].1.contains("USER_PRESENCE_INVALID"));
    assert!(refusals[2].1.contains("USER_PRESENCE_REQUIRED"));
    assert!(refusals[3].1.contains("USER_PRESENCE_NOT_REGISTERED"));
}
