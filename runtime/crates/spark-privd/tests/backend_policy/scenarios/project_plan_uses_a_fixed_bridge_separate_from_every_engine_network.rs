#[test]
fn project_plan_uses_a_fixed_bridge_separate_from_every_engine_network() {
    let (_root, backend, operation) = managed_project_fixture();
    let plan = backend
        .plan_start_project_container(&operation)
        .expect("valid project plan");
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
            .any(|argument| { argument == &format!("--network={INFERENCE_ISOLATED_NETWORK}") })
    );
    assert_eq!(plan.summary["network_mode"], "bridge");
    assert_eq!(plan.summary["host_network"], false);
    assert_eq!(plan.summary["engine_network_shared"], false);
    assert!(
        plan.argv
            .iter()
            .any(|argument| argument == "--publish=127.0.0.1:5173:5173")
    );
    // Every forwarded port is published on loopback only; nothing reaches the LAN directly.
    assert!(
        plan.argv
            .iter()
            .filter(|argument| argument.starts_with("--publish="))
            .all(|argument| argument.starts_with("--publish=127.0.0.1:"))
    );
}
