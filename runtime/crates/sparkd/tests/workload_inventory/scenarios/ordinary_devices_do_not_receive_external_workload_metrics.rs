#[tokio::test]
async fn ordinary_devices_do_not_receive_external_workload_metrics() {
    let harness = harness("observer", true);
    *harness.scripted_workloads.lock().unwrap() = Some(a_busy_host());

    let (status, body) = send(
        harness.state,
        signed_get(&harness.client, "/api/v1/telemetry"),
    )
    .await;

    // BH-17: host telemetry now needs Capability::TelemetryRead, so an observer never reaches the collector.
    assert_eq!(status, StatusCode::FORBIDDEN);
    assert_eq!(body["error"]["code"], "ROLE_FORBIDDEN");
    assert!(
        harness.observed_operations.lock().unwrap().is_empty(),
        "node status authority must not inspect external host workloads"
    );
}
