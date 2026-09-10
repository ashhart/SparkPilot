#[tokio::test]
async fn the_capability_document_reports_the_inventory_off_without_the_boundary() {
    let harness = harness("owner", false);
    let (status, capabilities) = send(
        harness.state,
        signed_get(&harness.client, "/api/v1/capabilities"),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(capabilities["features"]["workload_inventory"], false);
}
