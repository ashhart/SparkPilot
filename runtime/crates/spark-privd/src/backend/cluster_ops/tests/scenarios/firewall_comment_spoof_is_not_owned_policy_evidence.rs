#[test]
fn firewall_comment_spoof_is_not_owned_policy_evidence() {
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
    let runner = Arc::new(RecordingRunner::new());
    let spoofed_comments = [
        marker.clone(),
        format!("{marker}:allow-member-tcp"),
        format!("{marker}:allow-member-udp"),
        format!("{marker}:deny-fabric-tcp-from-lan"),
        format!("{marker}:deny-fabric-udp-from-lan"),
        format!("{marker}:deny-other-fabric"),
    ];
    runner.ok(
        Some(0),
        &serde_json::json!({
            "nftables": spoofed_comments
                .into_iter()
                .map(|comment| serde_json::json!({ "rule": { "comment": comment } }))
                .collect::<Vec<_>>()
        })
        .to_string(),
        "",
    );
    let backend =
        DockerBackend::new("docker", false).with_appliance_command_runner(runner.clone());

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
    assert_eq!(runner.argv_of(NFT_BIN).len(), 1);
}
