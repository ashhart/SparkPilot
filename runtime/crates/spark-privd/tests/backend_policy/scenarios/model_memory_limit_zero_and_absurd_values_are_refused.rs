fn start_with_memory_limit(limit: Option<u64>) -> PrivilegedOperation {
    let mut operation = start_operation(Uuid::new_v4());
    if let PrivilegedOperation::StartModel {
        memory_limit_bytes, ..
    } = &mut operation
    {
        *memory_limit_bytes = limit;
    }
    operation
}

/// Docker treats --memory=0 as unlimited, so zero must be refused at the boundary rather than forwarded.
#[test]
fn model_memory_limit_zero_and_absurd_values_are_refused() {
    let backend = DockerBackend::new("docker", true);
    for limit in [0, MAX_MODEL_MEMORY_LIMIT_BYTES + 1, u64::MAX] {
        let error = backend
            .plan_start_model(&start_with_memory_limit(Some(limit)))
            .err()
            .expect("an out-of-policy memory limit is refused");
        assert!(matches!(error, BackendError::InvalidInput(_)), "{limit}: {error}");
    }

    let plan = backend
        .plan_start_model(&start_with_memory_limit(Some(MAX_MODEL_MEMORY_LIMIT_BYTES)))
        .expect("the largest permitted limit plans");
    assert!(plan.argv.iter().any(|argument| {
        argument == &format!("--memory={MAX_MODEL_MEMORY_LIMIT_BYTES}")
    }));
    assert!(plan.argv.iter().any(|argument| {
        argument == &format!("--memory-swap={MAX_MODEL_MEMORY_LIMIT_BYTES}")
    }));

    // No limit at all leaves the cap to the engine policy rather than passing a zero through.
    let plan = backend
        .plan_start_model(&start_with_memory_limit(None))
        .expect("an absent limit plans");
    assert!(!plan.argv.iter().any(|argument| argument.starts_with("--memory")));
}
