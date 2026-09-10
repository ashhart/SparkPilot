#[tokio::test]
async fn unverified_import_is_gated() {
    // Flag off -> forbidden.
    let peer = full_peer(false);
    let (status, body) = send(
        &peer,
        Method::POST,
        "/api/v1/models/import",
        json!({ "repository": "some/repo", "revision": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" }),
    )
    .await;
    assert_eq!(status, StatusCode::FORBIDDEN);
    assert_eq!(body.unwrap()["error"]["code"], "MODEL_RECIPE_UNTRUSTED");

    // Flag on -> created, listed as unverified.
    let peer = full_peer(true);
    let key = uuid::Uuid::new_v4();
    let request = json!({ "repository": "some/repo", "revision": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" });
    let (status, body) = send_with_key(
        &peer,
        Method::POST,
        "/api/v1/models/import",
        request.clone(),
        key,
    )
    .await;
    assert_eq!(status, StatusCode::CREATED);
    let body = body.unwrap();
    assert_eq!(body["install_state"], "unverified");
    let (replay_status, replay) =
        send_with_key(&peer, Method::POST, "/api/v1/models/import", request, key).await;
    assert_eq!(replay_status, StatusCode::CREATED);
    assert_eq!(replay, Some(body));

    // Traversal in the import id is rejected rather than used as a path.
    let (status, _) = send(
        &peer,
        Method::POST,
        "/api/v1/models/import",
        json!({ "repository": "../escape", "revision": "x" }),
    )
    .await;
    assert_eq!(status, StatusCode::UNPROCESSABLE_ENTITY);
}
