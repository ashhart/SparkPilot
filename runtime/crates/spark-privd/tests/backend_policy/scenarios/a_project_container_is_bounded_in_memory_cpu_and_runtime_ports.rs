#[test]
fn a_project_container_is_bounded_in_memory_cpu_and_runtime_ports() {
    let (_root, backend, operation) = managed_project_fixture();
    let plan = backend
        .plan_start_project_container(&operation)
        .expect("valid project plan");

    // §42.3 and §33.5: a project container competes for the same unified memory the guard defends.
    assert!(
        plan.argv.contains(&format!(
            "--memory={}",
            spark_core::PROJECT_CONTAINER_MEMORY_BYTES
        )),
        "project container has no memory ceiling: {:?}",
        plan.argv
    );
    assert!(
        plan.argv.contains(&format!(
            "--memory-swap={}",
            spark_core::PROJECT_CONTAINER_MEMORY_BYTES
        )),
        "an unbounded swap ceiling lets the container exceed its memory limit: {:?}",
        plan.argv
    );
    assert!(
        plan.argv
            .contains(&format!("--cpus={}", spark_core::PROJECT_CONTAINER_CPUS)),
        "project container has no CPU ceiling: {:?}",
        plan.argv
    );
    assert_eq!(plan.summary["memory_limit_bytes"], spark_core::PROJECT_CONTAINER_MEMORY_BYTES);
}

#[test]
fn privileged_project_plan_rejects_every_runtime_owned_port() {
    for port in spark_core::RUNTIME_SERVICE_PORTS {
        let (_root, backend, mut operation) = managed_project_fixture();
        if let PrivilegedOperation::StartProjectContainer { forward_ports, .. } = &mut operation {
            *forward_ports = vec![port];
        }
        assert!(
            matches!(
                backend.plan_start_project_container(&operation),
                Err(BackendError::InvalidInput(_))
            ),
            "the privileged layer published a runtime-owned port {port}"
        );
    }
}
