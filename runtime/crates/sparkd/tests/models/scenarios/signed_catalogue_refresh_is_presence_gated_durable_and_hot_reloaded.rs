#[tokio::test]
async fn signed_catalogue_refresh_is_presence_gated_durable_and_hot_reloaded() {
    let peer = full_peer(false);
    let candidate_json = expanded_signed_catalogue_json();
    let (preview_status, preview) = send(
        &peer,
        Method::POST,
        "/api/v1/catalogue/refresh/preview",
        json!({ "candidate_json": candidate_json }),
    )
    .await;
    assert_eq!(preview_status, StatusCode::OK, "{preview:?}");
    let preview_digest = preview.unwrap()["preview_digest"]
        .as_str()
        .unwrap()
        .to_owned();
    let body = serde_json::to_vec(&json!({
        "candidate_json": expanded_signed_catalogue_json(),
        "accepted_preview_digest": preview_digest,
    }))
    .unwrap();

    let mut without_presence =
        signed_request(&peer, Method::POST, "/api/v1/catalogue/refresh", &body);
    without_presence
        .headers_mut()
        .remove(sparkd::user_presence::HEADER_USER_PRESENCE);
    let refusal = router(peer.state.clone())
        .oneshot(without_presence)
        .await
        .unwrap();
    assert_eq!(refusal.status(), StatusCode::FORBIDDEN);

    let apply_key = uuid::Uuid::new_v4();
    let response = router(peer.state.clone())
        .oneshot(signed_request_with_key(
            &peer,
            Method::POST,
            "/api/v1/catalogue/refresh",
            &body,
            apply_key,
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::ACCEPTED);
    let first: Value =
        serde_json::from_slice(&to_bytes(response.into_body(), 1 << 20).await.unwrap()).unwrap();
    let replay = router(peer.state.clone())
        .oneshot(signed_request_with_key(
            &peer,
            Method::POST,
            "/api/v1/catalogue/refresh",
            &body,
            apply_key,
        ))
        .await
        .unwrap();
    assert_eq!(replay.status(), StatusCode::ACCEPTED);
    let replay: Value =
        serde_json::from_slice(&to_bytes(replay.into_body(), 1 << 20).await.unwrap()).unwrap();
    assert_eq!(replay["id"], first["id"]);

    let mut complete = false;
    for _ in 0..100 {
        let (status, catalogue) = get(&peer, "/api/v1/catalogue").await;
        assert_eq!(status, StatusCode::OK);
        if catalogue.unwrap()["recipe_count"] == 2 {
            complete = true;
            break;
        }
        tokio::task::yield_now().await;
    }
    assert!(complete, "durable refresh did not complete");
    let (_, catalogue) = get(&peer, "/api/v1/catalogue").await;
    assert_eq!(catalogue.unwrap()["previous_snapshot_available"], true);
    let (status, models) = get(&peer, "/api/v1/models").await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(models.unwrap()["items"].as_array().unwrap().len(), 2);
}
