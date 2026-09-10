#[tokio::test]
async fn an_externally_named_container_cannot_pose_as_a_managed_one() {
    let harness = harness("owner", true);
    *harness.scripted_workloads.lock().unwrap() = Some(ObservedWorkloads {
        containers: vec![
            container("9f2c", Some("spark-model-latest"), Some("acme/x:1")),
            container("1a3b", Some("spark-open-webui-copy"), Some("acme/x:1")),
            // Use a syntactically valid generated-looking id absent from runtime records to test false ownership claims.
            container(
                "7e5d",
                Some("spark-model-3f0e0b6a-7d3a-4c2a-9b6e-1a2b3c4d5e6f"),
                Some("nginx:latest"),
            ),
        ],
        truncated: false,
        unreadable_lines: 0,
    });

    let (_, body) = send(
        harness.state,
        signed_get(&harness.client, "/api/v1/workloads"),
    )
    .await;

    for workload in body["workloads"].as_array().unwrap() {
        assert_ne!(
            workload["ownership"], "spark_managed",
            "a name in this runtime's space still needs an id it could have minted: {workload}"
        );
    }
}
