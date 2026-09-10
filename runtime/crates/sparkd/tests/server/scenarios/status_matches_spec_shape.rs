#[tokio::test]
async fn status_matches_spec_shape() {
    let (state, client) = test_state();
    let (status, body) = get_json(state, &client, "/api/v1/status").await;

    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["system"]["memory_pressure"], "normal");
    assert_eq!(body["system"]["cpu_utilisation"], 0.18);
    assert_eq!(body["inference"]["state"], "unloaded");
    assert_eq!(body["operations"]["active"], 0);
    assert_eq!(body["api_version"], 1);
    assert!(body["cluster"].is_null());
}
