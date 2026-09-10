#[tokio::test]
async fn managed_and_external_workloads_are_reported_as_different_states() {
    // Show runtime-managed and externally managed workloads as distinct ownership states.
    let harness = harness("owner", true);
    *harness.scripted_workloads.lock().unwrap() = Some(a_busy_host());

    let (status, body) = send(
        harness.state,
        signed_get(&harness.client, "/api/v1/workloads"),
    )
    .await;

    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["available"], true);
    assert_eq!(body["truncated"], false);
    assert_eq!(body["workloads"].as_array().map(Vec::len), Some(3));

    let managed = workload_named(&body, &format!("spark-model-{RECORDED_ENGINE_ID}"));
    assert_eq!(managed["ownership"], "spark_managed");
    assert_eq!(managed["kind"], "inference_engine");

    let external = workload_named(&body, "deepseek-serve");
    assert_eq!(external["ownership"], "external_observed");
    assert_eq!(external["recognised_engine"], "sglang");
    assert_eq!(external["published_ports"][0]["host_port"], 30000);

    let unknown = workload_named(&body, "legacy-batch-job");
    assert_eq!(unknown["ownership"], "unknown_external");
    assert_eq!(unknown["recognised_engine"], "none");
    assert_eq!(unknown["kind"], "unknown");
}
