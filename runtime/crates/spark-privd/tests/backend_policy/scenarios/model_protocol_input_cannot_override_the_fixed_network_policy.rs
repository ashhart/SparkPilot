#[test]
fn model_protocol_input_cannot_override_the_fixed_network_policy() {
    let backend = DockerBackend::new("docker", true);
    let mut encoded = serde_json::to_value(start_operation(Uuid::new_v4())).unwrap();
    encoded["network"] = serde_json::json!("host");
    encoded["network_mode"] = serde_json::json!("container:project-victim");
    encoded["docker_args"] = serde_json::json!(["--privileged", "--publish=0.0.0.0:8000:8000"]);
    let decoded: PrivilegedOperation = serde_json::from_value(encoded).unwrap();
    let plan = backend
        .plan_start_model(&decoded)
        .expect("typed request keeps the signed policy");

    assert_eq!(
        plan.argv
            .iter()
            .filter(|argument| argument.starts_with("--network="))
            .map(String::as_str)
            .collect::<Vec<_>>(),
        ["--network=spark-inference-isolated"]
    );
    assert!(!plan.argv.iter().any(|argument| argument == "--privileged"));
    assert!(
        !plan
            .argv
            .iter()
            .any(|argument| argument.starts_with("--publish=0.0.0.0:"))
    );
}
