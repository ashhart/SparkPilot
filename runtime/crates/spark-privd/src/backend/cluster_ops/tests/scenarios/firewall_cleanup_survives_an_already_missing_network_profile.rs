#[test]
fn firewall_cleanup_survives_an_already_missing_network_profile() {
    let transaction_id = Uuid::from_u128(1);
    let cluster_id = Uuid::from_u128(2);
    let local_node_id = Uuid::from_u128(3);
    let peer_node_id = Uuid::from_u128(4);
    let local_address = Ipv4Addr::new(172, 31, 252, 1);
    let peer_address = Ipv4Addr::new(172, 31, 252, 2);
    let marker = cluster_firewall_owner_marker(
        transaction_id,
        cluster_id,
        local_node_id,
        peer_node_id,
        local_address,
        peer_address,
        "cx7p1",
    );
    let table = cluster_firewall_table(cluster_id, transaction_id);
    let runner = Arc::new(RecordingRunner::new());
    runner.ok(
        Some(0),
        &firewall_json(&table, &marker, "cx7p1", local_address, peer_address),
        "",
    );
    runner.ok(
        Some(0),
        &firewall_json(&table, &marker, "cx7p1", local_address, peer_address),
        "",
    );
    runner.ok(Some(0), "", "");
    runner.ok(Some(1), "", "No such file or directory");
    let backend =
        DockerBackend::new("docker", false).with_appliance_command_runner(runner.clone());

    assert!(
        cleanup_cluster_firewall_without_profile(
            &backend,
            transaction_id,
            cluster_id,
            local_node_id,
            peer_node_id,
            local_address,
            peer_address,
        )
        .unwrap()
    );
    assert_eq!(runner.argv_of(NFT_BIN).len(), 4);
}
