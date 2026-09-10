#[test]
fn two_rank_collective_uses_full_identity_labels_without_a_shell() {
    let transaction_id = Uuid::parse_str("12345678-1234-1234-1234-123456789abc").unwrap();
    let cluster_id = Uuid::parse_str("87654321-4321-4321-4321-cba987654321").unwrap();
    let local_node_id = Uuid::from_u128(3);
    let command = TwoRankCommand {
        transaction_id,
        cluster_id,
        local_node_id,
        coordinator_address: Ipv4Addr::new(172, 31, 252, 1),
        node_rank: 1,
        image_digest: IMAGE_A,
        fabric_interface: "cx7",
    };
    let argv = two_rank_collective_argv("/usr/bin/docker", &command);
    assert_eq!(argv[0], TIMEOUT_BIN);
    assert_eq!(argv[3], "180s");
    assert!(argv.contains(&format!(
        "--name=spark-cluster-probe-{}-{}-1",
        transaction_id.simple(),
        local_node_id.simple(),
    )));
    assert!(argv.contains(&format!("--label=spark.transaction-id={transaction_id}")));
    assert!(argv.contains(&format!("--label=spark.cluster-id={cluster_id}")));
    assert!(argv.contains(&format!("--label=spark.local-node-id={local_node_id}")));
    assert!(argv.contains(&"--env=NCCL_SOCKET_IFNAME=cx7".into()));
    assert!(argv.contains(&"--env=GLOO_SOCKET_IFNAME=cx7".into()));
    assert!(
        !argv
            .iter()
            .any(|value| matches!(value.as_str(), "sh" | "bash"))
    );
}
