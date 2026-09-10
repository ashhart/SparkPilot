#[test]
fn firewall_cleanup_never_deletes_changed_owned_policy() {
    let transaction_id = Uuid::from_u128(1);
    let cluster_id = Uuid::from_u128(2);
    let local_node_id = Uuid::from_u128(3);
    let peer_node_id = Uuid::from_u128(4);
    let local_address = Ipv4Addr::new(172, 31, 252, 1);
    let peer_address = Ipv4Addr::new(172, 31, 252, 2);
    let interface = "cx7p1";
    let table = cluster_firewall_table(cluster_id, transaction_id);
    let marker = cluster_firewall_owner_marker(
        transaction_id,
        cluster_id,
        local_node_id,
        peer_node_id,
        local_address,
        peer_address,
        interface,
    );
    let mut changed =
        firewall_json_value(&table, &marker, interface, local_address, peer_address);
    let duplicate = changed["nftables"][6].clone();
    changed["nftables"].as_array_mut().unwrap().push(duplicate);
    let runner = Arc::new(RecordingRunner::new());
    runner.ok(Some(0), &changed.to_string(), "");
    let backend =
        DockerBackend::new("docker", false).with_appliance_command_runner(runner.clone());

    assert!(
        cleanup_cluster_firewall(
            &backend,
            transaction_id,
            cluster_id,
            local_node_id,
            peer_node_id,
            local_address,
            peer_address,
            interface,
        )
        .is_err()
    );
    let commands = runner.argv_of(NFT_BIN);
    assert_eq!(commands.len(), 1);
    assert!(!commands[0].iter().any(|argument| argument == "delete"));
}
