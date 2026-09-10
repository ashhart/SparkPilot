#[tokio::test]
async fn fabric_endpoint_binds_only_reciprocal_authenticated_peer_evidence() {
    let (mut state, client, database, _guard) =
        test_state("observer", healthy_report(), CollectiveOutcome::Passed);
    let local = state.identity.node_id().to_string();
    let peer = uuid::Uuid::new_v4().to_string();
    let ids = vec![local.clone(), peer.clone()];
    record_peer_facts(&database, &facts_for(&ids, "paired", "0.1.0"));
    record_reciprocal_fabric_proof(&database, &local, "cx:p0", &peer, "cx:p1");
    state = state.with_fabric_status_provider(Arc::new(FixedFabricStatus {
        status: FabricStatus {
            observed_at: String::new(),
            available: true,
            unavailable_reason: None,
            configuration_owner: "externally_configured".into(),
            automatic_topology_available: false,
            takeover_available: false,
            address_evidence_available: true,
            route_evidence_available: true,
            netplan_evidence_available: true,
            netplan_sources: vec!["90-external.yaml".into()],
            ports: vec![FabricPortStatus {
                port_id: "cx:p0".into(),
                interfaces: vec!["enp1s0f0np0".into()],
                physical_link: "negotiated_200_gbe".into(),
                negotiated_speed_mbps: Some(200_000),
                mtu: Some(9000),
                addresses: vec!["10.20.0.1/24".into()],
                routes: vec!["10.20.0.0/24".into()],
                peer_proof: "unknown".into(),
                authenticated_peer_node_id: None,
                peer_proof_expires_at: None,
            }],
        },
    }));

    let (status, value) = send(
        state,
        signed_request(&client, "GET", "/api/v1/fabric", None),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(value["ports"][0]["peer_proof"], "authenticated_node");
    assert_eq!(value["ports"][0]["authenticated_peer_node_id"], peer);
    assert_eq!(value["configuration_owner"], "externally_configured");
    assert_eq!(value["automatic_topology_available"], false);
    assert_eq!(value["takeover_available"], false);
}
