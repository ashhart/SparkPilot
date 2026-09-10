#[tokio::test]
async fn failed_catalogue_persistence_restores_the_previous_snapshot_and_live_inventory() {
    let peer = full_peer(false);
    let catalogue_path = peer.state.config.data_dir.join("catalogue.json");
    let original = std::fs::read(&catalogue_path).unwrap();
    let candidate_json = expanded_signed_catalogue_json();
    let (_, preview) = send(
        &peer,
        Method::POST,
        "/api/v1/catalogue/refresh/preview",
        json!({ "candidate_json": candidate_json }),
    )
    .await;
    let preview_digest = preview.unwrap()["preview_digest"]
        .as_str()
        .unwrap()
        .to_owned();
    peer.state
        .database
        .as_ref()
        .unwrap()
        .lock()
        .execute_batch(
            "CREATE TRIGGER reject_catalogue_state
             BEFORE INSERT ON catalogue_refresh_state
             BEGIN SELECT RAISE(ABORT, 'forced persistence failure'); END;",
        )
        .unwrap();
    let body = serde_json::to_vec(&json!({
        "candidate_json": expanded_signed_catalogue_json(),
        "accepted_preview_digest": preview_digest,
    }))
    .unwrap();
    let response = router(peer.state.clone())
        .oneshot(signed_request(
            &peer,
            Method::POST,
            "/api/v1/catalogue/refresh",
            &body,
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::ACCEPTED);

    let mut failed = false;
    for _ in 0..100 {
        let state: Option<String> = peer
            .state
            .database
            .as_ref()
            .unwrap()
            .lock()
            .query_row(
                "SELECT state FROM operations WHERE kind = 'catalogue.refresh' ORDER BY created_at DESC LIMIT 1",
                [],
                |row| row.get(0),
            )
            .ok();
        if state.as_deref() == Some("failed") {
            failed = true;
            break;
        }
        tokio::time::sleep(Duration::from_millis(5)).await;
    }
    assert!(failed, "refresh did not report its persistence failure");
    assert_eq!(std::fs::read(&catalogue_path).unwrap(), original);
    let (_, models) = get(&peer, "/api/v1/models").await;
    assert_eq!(models.unwrap()["items"].as_array().unwrap().len(), 1);
}
