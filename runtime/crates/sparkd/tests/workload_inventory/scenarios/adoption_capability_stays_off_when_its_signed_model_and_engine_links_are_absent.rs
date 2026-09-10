#[tokio::test]
async fn adoption_capability_stays_off_when_its_signed_model_and_engine_links_are_absent() {
    // Keep adoption disabled when inventory lacks signed catalogue and lifecycle-manager support.
    let harness = harness("owner", true);
    *harness.scripted_workloads.lock().unwrap() = Some(a_busy_host());

    let (status, body) = send(
        harness.state.clone(),
        signed_get(&harness.client, "/api/v1/workloads"),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["adoption_supported"], false);
    for workload in body["workloads"].as_array().unwrap() {
        assert_ne!(workload["ownership"], "adoption_available");
    }

    let (status, capabilities) = send(
        harness.state,
        signed_get(&harness.client, "/api/v1/capabilities"),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(capabilities["features"]["workload_adoption"], false);
    assert_eq!(capabilities["features"]["workload_inventory"], true);
}
