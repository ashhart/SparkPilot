#[tokio::test]
async fn the_inventory_needs_an_authenticated_device() {
    let harness = harness("owner", true);
    *harness.scripted_workloads.lock().unwrap() = Some(a_busy_host());
    let request = Request::builder()
        .method(Method::GET)
        .uri("/api/v1/workloads")
        .body(axum::body::Body::empty())
        .unwrap();
    let (status, _) = send(harness.state, request).await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);
}
