#[test]
fn liveness_argv_requires_both_nodes_and_one_execution_digest() {
    let local = Uuid::from_u128(3);
    let peer = Uuid::from_u128(4);
    let digest = "e".repeat(64);
    let argv = membership_argv("owned", local, peer, &digest, RAY_PROBE_ATTEMPTS);
    assert_eq!(argv[0], "exec");
    assert_eq!(argv[2], "python3");
    assert!(argv.contains(&cluster_node_resource(local)));
    assert!(argv.contains(&cluster_node_resource(peer)));
    assert!(argv.contains(&execution_resource(&digest)));
    assert!(CLUSTER_LIVENESS_SCRIPT.contains("execution_keys=={expected_execution}"));
}
