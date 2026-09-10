#[test]
fn single_node_launch_accepts_one_million_context_but_refuses_larger_limits() {
    let backend = DockerBackend::new("docker", true);
    let mut operation = start_operation(Uuid::new_v4());
    if let PrivilegedOperation::StartModel {
        max_model_length,
        max_sequences,
        ..
    } = &mut operation
    {
        *max_model_length = 1_048_576;
        *max_sequences = 64;
    }
    let plan = backend.plan_start_model(&operation).unwrap();
    assert!(
        plan.argv
            .windows(2)
            .any(|pair| pair == ["--max-model-len", "1048576"])
    );
    assert!(
        plan.argv
            .windows(2)
            .any(|pair| pair == ["--max-num-seqs", "64"])
    );

    if let PrivilegedOperation::StartModel {
        max_model_length, ..
    } = &mut operation
    {
        *max_model_length += 1;
    }
    assert!(matches!(
        backend.plan_start_model(&operation),
        Err(BackendError::InvalidInput(_))
    ));
    if let PrivilegedOperation::StartModel {
        max_model_length,
        max_sequences,
        ..
    } = &mut operation
    {
        *max_model_length = 1_048_576;
        *max_sequences = 65;
    }
    assert!(matches!(
        backend.plan_start_model(&operation),
        Err(BackendError::InvalidInput(_))
    ));
}
