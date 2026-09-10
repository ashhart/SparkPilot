/// Report saturated analysis workers as retryable 503 capacity refusal, without model conflicts or internal-error claims.
#[tokio::test]
async fn a_saturated_worker_pool_refuses_with_capacity_not_a_fault() {
    let (h, addr, owner, _observer) = harness().await;
    let client = reqwest::Client::new();
    load_model(&client, addr, &owner).await;
    // Every started analysis holds its worker for the whole delay.
    h.backend.set_non_stream_delay(Duration::from_secs(30));

    let capacity = h.state.jobs.worker_metrics().capacity;
    for index in 0..capacity {
        let (status, body) = post(
            &client,
            addr,
            &owner,
            "/api/v1/inference/analyses",
            analysis_body("Occupying a worker."),
        )
        .await;
        assert_eq!(status, 202, "analysis {index} of {capacity}: {body}");
    }

    let (status, refused) = post(
        &client,
        addr,
        &owner,
        "/api/v1/inference/analyses",
        analysis_body("One too many."),
    )
    .await;
    assert_eq!(status, 503, "{refused}");
    assert_eq!(refused["error"]["code"], "OPERATION_CAPACITY_EXCEEDED");
}
