#[test]
fn privileged_project_plan_rejects_the_engine_port_range() {
    for port in [
        spark_core::RESERVED_ENGINE_PORT_RANGE_START,
        spark_core::RESERVED_ENGINE_PORT_RANGE_END,
    ] {
        let (_root, backend, mut operation) = managed_project_fixture();
        if let PrivilegedOperation::StartProjectContainer { forward_ports, .. } = &mut operation {
            *forward_ports = vec![port];
        }
        assert!(matches!(
            backend.plan_start_project_container(&operation),
            Err(BackendError::InvalidInput(_))
        ));
    }
}
