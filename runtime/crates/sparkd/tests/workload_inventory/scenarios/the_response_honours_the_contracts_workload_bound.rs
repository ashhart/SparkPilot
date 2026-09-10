#[tokio::test]
async fn the_response_honours_the_contracts_workload_bound() {
    // Enforce the published workload limit even when the trusted helper returns more rows.
    let harness = harness("owner", true);
    let containers = (0..80)
        .map(|index| {
            container(
                &format!("{index:04x}"),
                Some(&format!("service-{index}")),
                Some("acme/x:1"),
            )
        })
        .collect();
    *harness.scripted_workloads.lock().unwrap() = Some(ObservedWorkloads {
        containers,
        truncated: false,
        unreadable_lines: 0,
    });

    let (status, body) = send(
        harness.state,
        signed_get(&harness.client, "/api/v1/workloads"),
    )
    .await;

    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["workloads"].as_array().map(Vec::len), Some(64));
    assert_eq!(body["truncated"], true);
}
