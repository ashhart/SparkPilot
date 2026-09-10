/// Reject oversized bodies as client errors without first reading the entire body.
#[tokio::test]
async fn a_body_over_the_limit_is_refused() {
    let harness = harness();
    let oversized = vec![b'x'; 17 * 1024 * 1024];
    let (status, _) = send(
        harness.state.clone(),
        signed(&harness, "POST", "/api/v1/inference/load", &oversized),
    )
    .await;
    assert!(
        status.is_client_error(),
        "a 17 MiB body was answered {status}"
    );
}
