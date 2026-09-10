#[tokio::test]
async fn the_response_matches_the_published_contract() {
    // Decode the response through generated contracts to catch client-visible schema drift.
    let harness = harness("owner", true);
    *harness.scripted_workloads.lock().unwrap() = Some(a_busy_host());

    let (status, body) = send(
        harness.state,
        signed_get(&harness.client, "/api/v1/workloads"),
    )
    .await;
    assert_eq!(status, StatusCode::OK);

    let inventory: spark_contracts::generated::WorkloadInventory =
        serde_json::from_value(body.clone()).expect("response must match the generated contract");
    assert!(inventory.available);
    assert!(!inventory.adoption_supported);
    assert_eq!(inventory.workloads.len(), 3);
    assert_eq!(
        inventory.workloads[0].ownership,
        spark_contracts::generated::WorkloadOwnership::SparkManaged
    );
    assert_eq!(
        inventory.workloads[1].ownership,
        spark_contracts::generated::WorkloadOwnership::ExternalObserved
    );
    assert_eq!(
        inventory.workloads[2].ownership,
        spark_contracts::generated::WorkloadOwnership::UnknownExternal
    );

    let unavailable = harness_unavailable_body().await;
    let _: spark_contracts::generated::WorkloadInventory =
        serde_json::from_value(unavailable).expect("the unavailable shape is also the contract");
}
