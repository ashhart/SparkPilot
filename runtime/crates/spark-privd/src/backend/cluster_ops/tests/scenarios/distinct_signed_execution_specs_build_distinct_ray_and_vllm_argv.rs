#[test]
fn distinct_signed_execution_specs_build_distinct_ray_and_vllm_argv() {
    let snapshot_a = "/var/lib/spark-runtime/models/snapshots/example/model-a/rev-a";
    let snapshot_b = "/var/lib/spark-runtime/models/snapshots/example/model-b/rev-b";
    let backend = DockerBackend::new("/usr/bin/docker", true);
    let first = start_operation("example/model-a", "balanced", IMAGE_A, snapshot_a);
    let second = start_operation("example/model-b", "throughput", IMAGE_B, snapshot_b);
    let first_spec = ClusterLaunchSpec::from_operation(&backend, &first).unwrap();
    let second_spec = ClusterLaunchSpec::from_operation(&backend, &second).unwrap();
    let (_, _, first_ray) = ray_member_argv("/usr/bin/docker", &first_spec, "cx7");
    let (_, _, first_engine) = engine_argv("/usr/bin/docker", &first_spec, "cx7");
    let (_, _, second_ray) = ray_member_argv("/usr/bin/docker", &second_spec, "cx7");
    let (_, _, second_engine) = engine_argv("/usr/bin/docker", &second_spec, "cx7");

    assert!(first_ray.contains(&IMAGE_A.into()));
    assert!(first_ray.contains(&format!("--volume={snapshot_a}:/model:ro")));
    assert!(first_ray.iter().any(|argument| {
        argument.starts_with("--resources=")
            && argument.contains(&cluster_node_resource(first_spec.local_node_id))
            && argument.contains(&execution_resource(first_spec.execution_digest))
    }));
    assert!(first_engine.contains(&IMAGE_A.into()));
    assert!(first_engine.contains(&"example/model-a".into()));
    assert!(first_engine.contains(&"--distributed-executor-backend".into()));
    assert!(first_engine.contains(&"ray".into()));
    assert!(first_engine.contains(&"--tensor-parallel-size".into()));
    assert!(first_engine.contains(&"2".into()));
    assert!(first_engine.contains(&"127.0.0.1".into()));
    assert!(first_engine.contains(&"--env=NCCL_SOCKET_IFNAME=cx7".into()));
    assert!(second_ray.contains(&IMAGE_B.into()));
    assert!(second_engine.contains(&IMAGE_B.into()));
    assert!(second_engine.contains(&format!("--volume={snapshot_b}:/model:ro")));
    assert_ne!(first_spec.execution_digest, second_spec.execution_digest);
    assert_ne!(first_engine, second_engine);
    assert!(
        !first_engine
            .iter()
            .any(|value| matches!(value.as_str(), "sh" | "bash"))
    );
}
