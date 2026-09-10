#[tokio::test]
async fn status_reports_the_remote_service_mode_instead_of_disabled() {
    let (mut state, client) = test_state();
    let database = state.database.as_ref().expect("remote database").clone();
    let remote = Arc::new(
        RemoteAccessService::new(database, state.events.clone(), state.identity.node_id().to_string())
        .with_private_overlay_probe(Arc::new(ReachableTestOverlay)),
    );
    remote
        .enable("private_overlay")
        .expect("enable test overlay");
    state = state.with_remote(remote);

    let (status, body) = get_json(state, &client, "/api/v1/status").await;

    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["connection"]["remote_access"], "private_overlay");
}
