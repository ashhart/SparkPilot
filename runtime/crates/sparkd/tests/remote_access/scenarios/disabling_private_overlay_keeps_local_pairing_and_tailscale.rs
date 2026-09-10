#[tokio::test]
async fn disabling_private_overlay_keeps_local_pairing_and_tailscale() {
    let (state, client, database, _guard) = test_state("owner");
    let body = preview_enable_body(&state, &client, "private_overlay", None).await;
    let (status, value) = send(
        state.clone(),
        signed_request(
            &client,
            "POST",
            "/api/v1/remote/enable",
            Some(&body),
            vec![],
        ),
    )
    .await;
    assert_eq!(status, StatusCode::ACCEPTED);
    assert_eq!(
        wait_for_remote_operation(&database, value["id"].as_str().unwrap()),
        "succeeded"
    );

    let body = preview_disable_body(&state, &client).await;
    let (status, value) = send(
        state.clone(),
        signed_request(
            &client,
            "POST",
            "/api/v1/remote/disable",
            Some(&body),
            vec![],
        ),
    )
    .await;
    assert_eq!(status, StatusCode::ACCEPTED);
    assert_eq!(
        wait_for_remote_operation(&database, value["id"].as_str().unwrap()),
        "succeeded"
    );

    let service = state.remote.clone().unwrap();
    let device_id = client.device_id.to_string();
    let (status, value) = send(
        state,
        signed_request(&client, "GET", "/api/v1/remote", None, vec![]),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(value["enabled"], false);
    assert!(service.private_overlay_route().unwrap().is_some());
    let count: i64 = database.lock().query_row("SELECT COUNT(*) FROM devices WHERE id = ?1", [device_id], |row| row.get(0)).unwrap();
    assert_eq!(count, 1);
}
