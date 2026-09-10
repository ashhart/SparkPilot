fn start_with_cache_budget(budget: Option<u64>) -> PrivilegedOperation {
    let mut operation = start_operation(Uuid::new_v4());
    if let PrivilegedOperation::StartModel {
        kv_cache_memory_bytes,
        ..
    } = &mut operation
    {
        *kv_cache_memory_bytes = budget;
    }
    operation
}

/// ADR-043: the recipe arithmetic reaches vLLM as `--kv-cache-memory-bytes`, bounded like the container cap.
#[test]
fn an_engine_cache_budget_is_forwarded_as_an_absolute_flag_within_policy() {
    let backend = DockerBackend::new("docker", true);
    let plan = backend
        .plan_start_model(&start_with_cache_budget(Some(13_287_555_072)))
        .expect("a positive budget plans");
    assert!(
        plan.argv
            .windows(2)
            .any(|pair| pair == ["--kv-cache-memory-bytes", "13287555072"])
    );
    // The utilisation share stays on the command line as the fallback bound the engine still honours for profiling.
    assert!(
        plan.argv
            .windows(2)
            .any(|pair| pair == ["--gpu-memory-utilization", "0.700"])
    );
    let plan = backend
        .plan_start_model(&start_with_cache_budget(None))
        .expect("an absent budget plans");
    assert!(
        !plan
            .argv
            .iter()
            .any(|argument| argument == "--kv-cache-memory-bytes")
    );
    for budget in [0, MAX_MODEL_MEMORY_LIMIT_BYTES + 1, u64::MAX] {
        let error = backend
            .plan_start_model(&start_with_cache_budget(Some(budget)))
            .err()
            .expect("an out-of-policy cache budget is refused");
        assert!(
            matches!(error, BackendError::InvalidInput(_)),
            "{budget}: {error}"
        );
    }
}
