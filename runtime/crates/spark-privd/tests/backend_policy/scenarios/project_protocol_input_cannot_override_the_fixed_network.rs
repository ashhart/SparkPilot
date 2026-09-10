#[test]
fn project_protocol_input_cannot_override_the_fixed_network() {
    let (_root, backend, operation) = managed_project_fixture();
    let mut encoded = serde_json::to_value(operation).unwrap();
    encoded["network_mode"] = serde_json::json!("host");
    encoded["network"] = serde_json::json!("container:spark-model-victim");
    let decoded: PrivilegedOperation = serde_json::from_value(encoded).unwrap();
    let plan = backend
        .plan_start_project_container(&decoded)
        .expect("typed request keeps the fixed network");
    let network_arguments: Vec<_> = plan
        .argv
        .iter()
        .filter(|argument| argument.starts_with("--network="))
        .map(String::as_str)
        .collect();

    assert_eq!(network_arguments, ["--network=bridge"]);
    assert!(
        !plan
            .argv
            .iter()
            .any(|argument| argument == "--network=host")
    );
    assert!(
        !plan
            .argv
            .iter()
            .any(|argument| argument.starts_with("--network=container:"))
    );
}
