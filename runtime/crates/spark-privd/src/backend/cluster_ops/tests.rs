use super::collective::{TwoRankCommand, collective_test_argv, two_rank_collective_argv};
use super::launch_plan::{cluster_node_resource, execution_resource};
use super::link_configuration::cluster_link_phase_args;
use super::link_discovery::{
    ClusterProfileEvidence, choose_connectx_candidate, parse_active_ethernet_devices,
    parse_default_route_devices,
};
use super::*;
use crate::update::RecordingRunner;
use std::sync::Arc;
use uuid::Uuid;

const IMAGE_A: &str =
    "registry.example/vllm@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const IMAGE_B: &str =
    "registry.example/vllm@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";

fn start_operation(
    recipe_id: &str,
    profile_id: &str,
    image_digest: &str,
    snapshot: &str,
) -> PrivilegedOperation {
    let cluster_id = Uuid::from_u128(1);
    let launch_id = Uuid::from_u128(2);
    let local_node_id = Uuid::from_u128(3);
    let peer_node_id = Uuid::from_u128(4);
    let coordinator_node_id = local_node_id;
    let recipe_digest = if image_digest == IMAGE_A {
        "c".repeat(64)
    } else {
        "d".repeat(64)
    };
    let host_port = 18_100 + (launch_id.as_u128() % 100) as u16;
    let execution_digest = cluster_execution_digest(ClusterExecutionDigestInput {
        cluster_id,
        launch_id,
        local_node_id,
        peer_node_id,
        coordinator_node_id,
        recipe_id,
        profile_id,
        recipe_digest: &recipe_digest,
        image_digest,
        served_name: recipe_id,
        model_snapshot: snapshot,
        host_port,
        gpu_memory_utilisation_milli: 700,
        max_model_length: 16_384,
        max_sequences: 4,
        max_batched_tokens: 8_192,
        tensor_parallel_size: 2,
    });
    PrivilegedOperation::StartClusterLaunch {
        request_id: Uuid::new_v4(),
        transaction_id: Uuid::from_u128(7),
        cluster_id,
        launch_id,
        local_node_id,
        peer_node_id,
        coordinator_node_id,
        local_address: Ipv4Addr::new(172, 31, 252, 1),
        peer_address: Ipv4Addr::new(172, 31, 252, 2),
        coordinator_address: Ipv4Addr::new(172, 31, 252, 1),
        recipe_id: recipe_id.into(),
        profile_id: profile_id.into(),
        recipe_digest,
        execution_digest,
        image_digest: image_digest.into(),
        served_name: recipe_id.into(),
        model_snapshot: snapshot.into(),
        host_port,
        gpu_memory_utilisation_milli: 700,
        max_model_length: 16_384,
        max_sequences: 4,
        max_batched_tokens: 8_192,
        tensor_parallel_size: 2,
    }
}

include!("tests/scenarios/every_network_manager_cluster_phase_has_a_finite_wait.rs");

include!("tests/scenarios/cluster_probe_launches_carry_the_crates_container_policy.rs");

include!("tests/scenarios/two_rank_collective_uses_full_identity_labels_without_a_shell.rs");

include!("tests/scenarios/cluster_profile_name_and_marker_bind_full_transaction_identity.rs");

fn firewall_json_value(
    table: &str,
    marker: &str,
    interface: &str,
    local_address: Ipv4Addr,
    peer_address: Ipv4Addr,
) -> serde_json::Value {
    let iif = serde_json::json!({ "meta": { "key": "iifname" } });
    let saddr = serde_json::json!({ "payload": { "protocol": "ip", "field": "saddr" } });
    let daddr = serde_json::json!({ "payload": { "protocol": "ip", "field": "daddr" } });
    let tcp_dport = serde_json::json!({
        "payload": { "protocol": "tcp", "field": "dport" }
    });
    let udp_dport = serde_json::json!({
        "payload": { "protocol": "udp", "field": "dport" }
    });
    let tcp_ports = serde_json::json!({
        "set": [
            6379,
            8265,
            { "range": [10001, 10003] },
            { "range": [11000, 11063] },
            { "range": [18100, 18199] },
            19443,
            { "range": [24000, 65535] }
        ]
    });
    let udp_ports = serde_json::json!({ "set": [{ "range": [24000, 65535] }] });
    let exact_match = |left: serde_json::Value, right: serde_json::Value| {
        serde_json::json!({
            "match": { "op": "==", "left": left, "right": right }
        })
    };

    serde_json::json!({
        "nftables": [
            {
                "table": {
                    "family": "inet",
                    "name": table,
                    "comment": marker
                }
            },
            {
                "chain": {
                    "family": "inet",
                    "table": table,
                    "name": "input",
                    "type": "filter",
                    "hook": "input",
                    "prio": -50,
                    "policy": "accept"
                }
            },
            {
                "rule": {
                    "family": "inet",
                    "table": table,
                    "chain": "input",
                    "expr": [
                        exact_match(iif.clone(), serde_json::json!(interface)),
                        exact_match(saddr.clone(), serde_json::json!(peer_address.to_string())),
                        exact_match(daddr.clone(), serde_json::json!(local_address.to_string())),
                        exact_match(tcp_dport.clone(), tcp_ports.clone()),
                        { "accept": null }
                    ],
                    "comment": format!("{marker}:allow-member-tcp")
                }
            },
            {
                "rule": {
                    "family": "inet",
                    "table": table,
                    "chain": "input",
                    "expr": [
                        exact_match(iif.clone(), serde_json::json!(interface)),
                        exact_match(saddr, serde_json::json!(peer_address.to_string())),
                        exact_match(daddr, serde_json::json!(local_address.to_string())),
                        exact_match(udp_dport.clone(), udp_ports.clone()),
                        { "accept": null }
                    ],
                    "comment": format!("{marker}:allow-member-udp")
                }
            },
            {
                "rule": {
                    "family": "inet",
                    "table": table,
                    "chain": "input",
                    "expr": [
                        exact_match(iif.clone(), serde_json::json!(interface)),
                        exact_match(tcp_dport, tcp_ports),
                        { "drop": null }
                    ],
                    "comment": format!("{marker}:deny-fabric-tcp-from-lan")
                }
            },
            {
                "rule": {
                    "family": "inet",
                    "table": table,
                    "chain": "input",
                    "expr": [
                        exact_match(iif.clone(), serde_json::json!(interface)),
                        exact_match(udp_dport, udp_ports),
                        { "drop": null }
                    ],
                    "comment": format!("{marker}:deny-fabric-udp-from-lan")
                }
            },
            {
                "rule": {
                    "family": "inet",
                    "table": table,
                    "chain": "input",
                    "expr": [
                        exact_match(iif, serde_json::json!(interface)),
                        { "drop": null }
                    ],
                    "comment": format!("{marker}:deny-other-fabric")
                }
            }
        ]
    })
}

fn firewall_json(
    table: &str,
    marker: &str,
    interface: &str,
    local_address: Ipv4Addr,
    peer_address: Ipv4Addr,
) -> String {
    let mut evidence = firewall_json_value(table, marker, interface, local_address, peer_address);
    let entries = evidence["nftables"].as_array_mut().unwrap();
    for (index, entry) in entries.iter_mut().enumerate() {
        entry
            .as_object_mut()
            .unwrap()
            .values_mut()
            .next()
            .unwrap()
            .as_object_mut()
            .unwrap()
            .insert("handle".into(), serde_json::json!(index + 1));
    }
    entries.insert(
        0,
        serde_json::json!({
            "metainfo": {
                "version": "1.0.9",
                "json_schema_version": 1
            }
        }),
    );
    evidence.to_string()
}

include!("tests/scenarios/member_firewall_allows_only_the_exact_peer_and_blocks_lan_ports.rs");

include!("tests/scenarios/firewall_install_reuse_cleanup_and_foreign_collision_are_fenced.rs");

include!("tests/scenarios/firewall_comment_spoof_is_not_owned_policy_evidence.rs");

include!("tests/scenarios/firewall_rejects_changed_table_chain_rules_and_extra_objects.rs");

include!("tests/scenarios/firewall_cleanup_never_deletes_changed_owned_policy.rs");

include!("tests/scenarios/firewall_cleanup_survives_an_already_missing_network_profile.rs");

include!("tests/scenarios/connectx_selection_excludes_active_and_default_route_devices.rs");

include!("tests/scenarios/malformed_interface_and_profile_evidence_fail_closed.rs");

include!(
    "tests/scenarios/owned_profile_requires_exact_addresses_routes_dns_and_autoconnect_policy.rs"
);

include!("tests/scenarios/distinct_signed_execution_specs_build_distinct_ray_and_vllm_argv.rs");

include!("tests/scenarios/digest_substitution_and_non_two_way_parallelism_are_rejected.rs");

include!("tests/scenarios/foreign_container_collision_fails_exact_ownership_check.rs");

include!("tests/scenarios/detached_or_exited_container_is_never_running_health_evidence.rs");

include!("tests/scenarios/liveness_argv_requires_both_nodes_and_one_execution_digest.rs");
