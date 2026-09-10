#[tokio::test]
async fn a_managed_engines_engine_word_comes_from_its_image() {
    // Use durable records for ownership and image evidence for the engine label.
    let harness = harness("owner", true);
    *harness.scripted_workloads.lock().unwrap() = Some(ObservedWorkloads {
        containers: vec![container(
            "9f2c",
            Some(&format!("spark-model-{RECORDED_ENGINE_ID}")),
            Some("lmsysorg/sglang:v0.4.1"),
        )],
        truncated: false,
        unreadable_lines: 0,
    });

    let (_, body) = send(
        harness.state,
        signed_get(&harness.client, "/api/v1/workloads"),
    )
    .await;

    let workload = &body["workloads"][0];
    assert_eq!(workload["ownership"], "spark_managed");
    assert_eq!(workload["recognised_engine"], "sglang");
}
