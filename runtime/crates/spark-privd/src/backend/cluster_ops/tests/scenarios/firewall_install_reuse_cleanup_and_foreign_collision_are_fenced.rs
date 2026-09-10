#[test]
fn firewall_install_reuse_cleanup_and_foreign_collision_are_fenced() {
    let transaction_id = Uuid::from_u128(1);
    let cluster_id = Uuid::from_u128(2);
    let local_node_id = Uuid::from_u128(3);
    let peer_node_id = Uuid::from_u128(4);
    let local_address = Ipv4Addr::new(172, 31, 252, 1);
    let peer_address = Ipv4Addr::new(172, 31, 252, 2);
    let interface = "cx7p1";
    let marker = cluster_firewall_owner_marker(
        transaction_id,
        cluster_id,
        local_node_id,
        peer_node_id,
        local_address,
        peer_address,
        interface,
    );
    let table = cluster_firewall_table(cluster_id, transaction_id);
    let runner = Arc::new(RecordingRunner::new());
    runner.ok(Some(1), "", "No such file or directory");
    runner.ok(Some(0), "", "");
    runner.ok(
        Some(0),
        &firewall_json(&table, &marker, interface, local_address, peer_address),
        "",
    );
    runner.ok(
        Some(0),
        &firewall_json(&table, &marker, interface, local_address, peer_address),
        "",
    );
    runner.ok(
        Some(0),
        &firewall_json(&table, &marker, interface, local_address, peer_address),
        "",
    );
    runner.ok(Some(0), "", "");
    runner.ok(Some(1), "", "No such file or directory");
    let backend =
        DockerBackend::new("docker", false).with_appliance_command_runner(runner.clone());
    assert!(
        !install_cluster_firewall(
            &backend,
            interface,
            transaction_id,
            cluster_id,
            local_node_id,
            peer_node_id,
            local_address,
            peer_address,
        )
        .unwrap()
    );
    assert!(
        install_cluster_firewall(
            &backend,
            interface,
            transaction_id,
            cluster_id,
            local_node_id,
            peer_node_id,
            local_address,
            peer_address,
        )
        .unwrap()
    );
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
        .unwrap()
    );
    assert!(runner.argv_of(NFT_BIN).iter().all(|argv| {
        !argv
            .iter()
            .any(|argument| matches!(argument.as_str(), "sh" | "bash" | "-c"))
    }));

    let foreign = Arc::new(RecordingRunner::new());
    foreign.ok(
        Some(0),
        &serde_json::json!({ "nftables": [{ "table": { "comment": "foreign" } }] }).to_string(),
        "",
    );
    let backend =
        DockerBackend::new("docker", false).with_appliance_command_runner(foreign.clone());
    assert!(
        install_cluster_firewall(
            &backend,
            interface,
            transaction_id,
            cluster_id,
            local_node_id,
            peer_node_id,
            local_address,
            peer_address,
        )
        .is_err()
    );
    assert_eq!(foreign.argv_of(NFT_BIN).len(), 1);
}
