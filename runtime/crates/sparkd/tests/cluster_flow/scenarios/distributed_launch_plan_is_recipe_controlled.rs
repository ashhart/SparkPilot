#[test]
fn distributed_launch_plan_is_recipe_controlled() {
    let plan = DistributedLaunchPlan::for_two_nodes("/models/llama-405b", 131_072, 256);
    assert_eq!(plan.tensor_parallel_size, 2);
    assert_eq!(plan.distributed_executor_backend, "ray");
    let arguments = plan.arguments();
    let joined = arguments.join(" ");
    assert!(joined.contains("--tensor-parallel-size 2"));
    assert!(joined.contains("--distributed-executor-backend ray"));
    assert!(joined.contains("--max-model-len 131072"));
    assert!(joined.contains("--max-num-seqs 256"));
    // Structured arguments, never a shell string with quoting hazards.
    assert!(!arguments.iter().any(|arg| arg.contains(' ')));
}
