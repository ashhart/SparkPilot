#[tokio::test]
async fn catalogue_refresh_status_is_owner_visible_and_device_local() {
    let peer = full_peer(false);
    let (status, body) = get(&peer, "/api/v1/catalogue").await;
    assert_eq!(status, StatusCode::OK, "{body:?}");
    let body = body.expect("catalogue status");
    assert_eq!(body["source"], "device_local_signed_snapshot");
    assert_eq!(body["refresh_available"], true);
    assert_eq!(body["recipe_count"], 1);
    assert_eq!(body["active_engine_unaffected"], true);
}
