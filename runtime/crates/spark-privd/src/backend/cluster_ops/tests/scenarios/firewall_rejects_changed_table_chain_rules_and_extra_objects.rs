#[test]
fn firewall_rejects_changed_table_chain_rules_and_extra_objects() {
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
    let valid = firewall_json_value(&table, &marker, interface, local_address, peer_address);
    let mut foreign_family = valid.clone();
    foreign_family["nftables"][0]["table"]["family"] = serde_json::json!("ip");
    let mut foreign_table = valid.clone();
    foreign_table["nftables"][0]["table"]["name"] = serde_json::json!("foreign");
    let mut foreign_comment = valid.clone();
    foreign_comment["nftables"][0]["table"]["comment"] = serde_json::json!("foreign-owner");
    let mut wrong_chain_name = valid.clone();
    wrong_chain_name["nftables"][1]["chain"]["name"] = serde_json::json!("forward");
    let mut wrong_chain_type = valid.clone();
    wrong_chain_type["nftables"][1]["chain"]["type"] = serde_json::json!("nat");
    let mut wrong_hook = valid.clone();
    wrong_hook["nftables"][1]["chain"]["hook"] = serde_json::json!("forward");
    let mut wrong_priority = valid.clone();
    wrong_priority["nftables"][1]["chain"]["prio"] = serde_json::json!(0);
    let mut wrong_policy = valid.clone();
    wrong_policy["nftables"][1]["chain"]["policy"] = serde_json::json!("drop");
    let mut wrong_expression = valid.clone();
    wrong_expression["nftables"][2]["rule"]["expr"][1]["match"]["right"] =
        serde_json::json!("172.31.252.99");
    let mut extra_rule = valid.clone();
    let duplicate = extra_rule["nftables"][6].clone();
    extra_rule["nftables"]
        .as_array_mut()
        .unwrap()
        .push(duplicate);
    let mut reordered_rules = valid.clone();
    reordered_rules["nftables"]
        .as_array_mut()
        .unwrap()
        .swap(2, 3);

    for (case, evidence) in [
        ("foreign family", foreign_family),
        ("foreign table", foreign_table),
        ("foreign comment", foreign_comment),
        ("wrong chain name", wrong_chain_name),
        ("wrong chain type", wrong_chain_type),
        ("wrong hook", wrong_hook),
        ("wrong priority", wrong_priority),
        ("wrong policy", wrong_policy),
        ("wrong expression", wrong_expression),
        ("extra rule", extra_rule),
        ("reordered rules", reordered_rules),
    ] {
        let runner = Arc::new(RecordingRunner::new());
        runner.ok(Some(0), &evidence.to_string(), "");
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
            .is_err(),
            "accepted {case}"
        );
        assert_eq!(runner.argv_of(NFT_BIN).len(), 1, "mutated {case}");
    }
}
