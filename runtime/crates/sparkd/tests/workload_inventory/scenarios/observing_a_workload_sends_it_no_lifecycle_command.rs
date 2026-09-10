#[tokio::test]
async fn observing_a_workload_sends_it_no_lifecycle_command() {
    // Assert the entire request emits only the read-only privileged observation operation.
    let harness = harness("owner", true);
    *harness.scripted_workloads.lock().unwrap() = Some(a_busy_host());

    let (status, _) = send(
        harness.state,
        signed_get(&harness.client, "/api/v1/workloads"),
    )
    .await;
    assert_eq!(status, StatusCode::OK);

    let operations = harness.observed_operations.lock().unwrap().clone();
    assert_eq!(
        operations,
        vec!["inventory_workloads".to_owned()],
        "observation must not reach any other privileged operation"
    );
}
