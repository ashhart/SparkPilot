#[test]
fn invalid_recipe_profile_image_path_port_and_limits_are_rejected() {
    let backend = DockerBackend::new("docker", true);

    for bad in ["../escape", "Balanced", "a b", "x!y", "upper/Path"] {
        let mut operation = start_operation(Uuid::new_v4());
        if let PrivilegedOperation::StartModel { recipe_id, .. } = &mut operation {
            *recipe_id = bad.into();
        }
        assert!(matches!(
            backend.plan_start_model(&operation),
            Err(BackendError::InvalidInput(_))
        ));

        let mut operation = start_operation(Uuid::new_v4());
        if let PrivilegedOperation::StartModel { profile_id, .. } = &mut operation {
            *profile_id = bad.into();
        }
        assert!(matches!(
            backend.plan_start_model(&operation),
            Err(BackendError::InvalidInput(_))
        ));
    }

    let mut cases = Vec::new();
    let mut unpinned = start_operation(Uuid::new_v4());
    if let PrivilegedOperation::StartModel { image_digest, .. } = &mut unpinned {
        *image_digest = "nvcr.io/nvidia/vllm:latest".into();
    }
    cases.push(unpinned);

    let mut escaped = start_operation(Uuid::new_v4());
    if let PrivilegedOperation::StartModel { model_snapshot, .. } = &mut escaped {
        *model_snapshot = "/etc".into();
    }
    cases.push(escaped);

    let mut wrong_port = start_operation(Uuid::new_v4());
    if let PrivilegedOperation::StartModel { host_port, .. } = &mut wrong_port {
        *host_port = 7443;
    }
    cases.push(wrong_port);

    let mut unsafe_memory = start_operation(Uuid::new_v4());
    if let PrivilegedOperation::StartModel {
        gpu_memory_utilisation_milli,
        ..
    } = &mut unsafe_memory
    {
        *gpu_memory_utilisation_milli = 999;
    }
    cases.push(unsafe_memory);

    for operation in cases {
        assert!(matches!(
            backend.plan_start_model(&operation),
            Err(BackendError::InvalidInput(_))
        ));
    }
}
