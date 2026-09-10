#[tokio::test]
async fn the_observation_is_a_get_and_needs_no_replay_key() {
    // Allow signed read-only inventory without an idempotency key because observation causes no mutation.
    let harness = harness("owner", true);
    *harness.scripted_workloads.lock().unwrap() = Some(a_busy_host());
    let (status, _) = send(
        harness.state.clone(),
        signed_get(&harness.client, "/api/v1/workloads"),
    )
    .await;
    assert_eq!(status, StatusCode::OK);

    // Sign the unsupported-method request so refusal proves routing policy rather than authentication failure.
    let (status, _) = send(
        harness.state,
        signed(&harness.client, Method::POST, "/api/v1/workloads"),
    )
    .await;
    assert_eq!(
        status,
        StatusCode::METHOD_NOT_ALLOWED,
        "the inventory must expose no mutating method"
    );
}
