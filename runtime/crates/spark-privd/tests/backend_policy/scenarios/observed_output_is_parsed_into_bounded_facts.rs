#[test]
fn observed_output_is_parsed_into_bounded_facts() {
    let runner = Arc::new(RecordingRunner::new());
    runner.ok(
        Some(0),
        "9f2c\tspark-model-2b0b0d1e\trunning\tvllm/vllm-openai@sha256:aa\t127.0.0.1:18000->8000/tcp\n\
         1a3b\tdeepseek-serve\trunning\tlmsysorg/sglang:v0.4.1\t0.0.0.0:30000->30000/tcp\n",
        "",
    );
    let backend = DockerBackend::new("docker", false).with_appliance_command_runner(runner.clone());

    let response = backend
        .execute(&PrivilegedOperation::InventoryWorkloads {
            request_id: Uuid::new_v4(),
        })
        .expect("observation");

    assert_eq!(response.code, "workloads_observed");
    let observed: spark_privd::workloads::ObservedWorkloads =
        serde_json::from_value(response.details).expect("decode");
    assert!(!observed.truncated);
    assert_eq!(observed.containers.len(), 2);
    assert_eq!(
        observed.containers[0].name.as_deref(),
        Some("spark-model-2b0b0d1e")
    );
    assert_eq!(observed.containers[1].ports[0].host_port, 30000);
}
