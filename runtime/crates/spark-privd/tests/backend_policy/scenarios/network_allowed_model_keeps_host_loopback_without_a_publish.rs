#[test]
fn network_allowed_model_keeps_host_loopback_without_a_publish() {
    let backend = DockerBackend::new("docker", true);
    let mut operation = start_operation(Uuid::new_v4());
    let PrivilegedOperation::StartModel {
        allow_network_during_inference,
        ..
    } = &mut operation
    else {
        unreachable!()
    };
    *allow_network_during_inference = true;
    let plan = backend.plan_start_model(&operation).unwrap();
    assert!(plan.argv.iter().any(|arg| arg == "--network=host"));
    assert!(!plan.argv.iter().any(|arg| arg.starts_with("--publish")));
    assert!(
        plan.argv
            .windows(2)
            .any(|pair| pair == ["--host", "127.0.0.1"])
    );
    let expected_port = operation_host_port(&operation).to_string();
    assert!(
        plan.argv
            .windows(2)
            .any(|pair| pair[0] == "--port" && pair[1] == expected_port)
    );
    assert_eq!(plan.summary["network_policy"], "recipe_allows_egress");
}
