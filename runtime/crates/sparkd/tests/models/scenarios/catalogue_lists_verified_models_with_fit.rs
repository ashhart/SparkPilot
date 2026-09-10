#[tokio::test]
async fn catalogue_lists_verified_models_with_fit() {
    let peer = full_peer(false);
    let (status, body) = get(&peer, "/api/v1/models").await;
    assert_eq!(status, StatusCode::OK);
    let body = body.unwrap();
    let items = body["items"].as_array().unwrap();
    assert_eq!(items.len(), 1);
    let model = &items[0];
    assert_eq!(model["id"], "example/model-32b");
    assert_eq!(model["install_state"], "available");
    assert_eq!(model["fit"], "smaller_profile_required"); // 101 GB needs more than the fake 26.8 GiB headroom
    assert_eq!(model["capabilities"]["chat"], true);
    assert_eq!(model["profiles"][0]["id"], "balanced-16k");
}
