use super::*;

fn interface(root: &Path, name: &str, port: &str, carrier: &str, speed: &str) {
    let directory = root.join(name);
    std::fs::create_dir_all(directory.join("device")).unwrap();
    std::fs::write(directory.join("device/vendor"), CONNECTX_VENDOR).unwrap();
    std::fs::write(directory.join("phys_port_name"), port).unwrap();
    std::fs::write(directory.join("carrier"), carrier).unwrap();
    std::fs::write(directory.join("speed"), speed).unwrap();
    std::fs::write(directory.join("mtu"), "9000").unwrap();
}

#[test]
fn external_configuration_evidence_is_read_without_claiming_ownership() {
    let sysfs = tempfile::tempdir().unwrap();
    let netplan = tempfile::tempdir().unwrap();
    interface(sysfs.path(), "enp1s0f0np0", "p0", "1", "200000");
    std::fs::write(
        netplan.path().join("90-external-cluster.yaml"),
        "network:\n  ethernets:\n    enp1s0f0np0:\n      addresses: [10.20.0.1/24]\n",
    )
    .unwrap();
    let status = observe_filesystem(
        sysfs.path(),
        netplan.path(),
        "2026-08-31T12:00:00Z",
        Some(
            r#"[{"ifname":"enp1s0f0np0","addr_info":[{"family":"inet","local":"10.20.0.1","prefixlen":24}]}]"#,
        ),
        Some(r#"[{"dev":"enp1s0f0np0","dst":"10.20.0.0/24"}]"#),
    );

    assert!(status.available);
    assert_eq!(status.configuration_owner, EXTERNALLY_CONFIGURED);
    assert!(!status.automatic_topology_available);
    assert!(!status.takeover_available);
    assert_eq!(status.netplan_sources, ["90-external-cluster.yaml"]);
    assert_eq!(status.ports.len(), 1);
    assert_eq!(status.ports[0].physical_link, "negotiated_200_gbe");
    assert_eq!(status.ports[0].addresses, ["10.20.0.1/24"]);
    assert_eq!(status.ports[0].routes, ["10.20.0.0/24"]);
    assert_eq!(status.ports[0].peer_proof, "unknown");
}

#[test]
fn carrier_does_not_become_peer_identity() {
    let sysfs = tempfile::tempdir().unwrap();
    let missing_netplan = sysfs.path().join("missing-netplan");
    interface(sysfs.path(), "ibp5s0", "p0", "1", "200000");
    let status = observe_filesystem(
        sysfs.path(),
        &missing_netplan,
        "2026-08-31T12:00:00Z",
        Some("[]"),
        Some("[]"),
    );

    assert_eq!(status.ports[0].physical_link, "negotiated_200_gbe");
    assert_eq!(status.ports[0].peer_proof, "unknown");
    assert_eq!(status.configuration_owner, "unconfigured");
}

fn link(local: &str, port: &str, peer: &str) -> AuthenticatedFabricLink {
    AuthenticatedFabricLink {
        member_a_node_id: local.into(),
        member_a_port_id: port.into(),
        member_b_node_id: peer.into(),
        member_b_port_id: "peer-port".into(),
        proof_source: "mutual_tls_challenge".into(),
        path_topology: "direct".into(),
        direct_connection_proven: true,
        verified_at: "2026-08-31T12:00:00Z".into(),
        expires_at: "2026-09-30T12:00:00Z".into(),
    }
}

#[test]
fn carrier_without_proof_is_a_candidate_and_never_a_trusted_member() {
    let sysfs = tempfile::tempdir().unwrap();
    let missing_netplan = sysfs.path().join("missing-netplan");
    interface(sysfs.path(), "ibp5s0", "p0", "1", "200000");
    let mut status = observe_filesystem(
        sysfs.path(),
        &missing_netplan,
        "2026-08-31T12:00:00Z",
        Some("[]"),
        Some("[]"),
    );
    bind_authenticated_peers(&mut status, "local-node", &[]);

    assert_eq!(status.ports[0].peer_proof, "candidate");
    assert!(status.ports[0].authenticated_peer_node_id.is_none());
    assert_eq!(status.configuration_owner, "unconfigured");
}

#[test]
fn a_down_port_stays_unknown_rather_than_becoming_a_candidate() {
    let sysfs = tempfile::tempdir().unwrap();
    let missing_netplan = sysfs.path().join("missing-netplan");
    interface(sysfs.path(), "ibp5s0", "p0", "0", "0");
    let mut status = observe_filesystem(
        sysfs.path(),
        &missing_netplan,
        "2026-08-31T12:00:00Z",
        Some("[]"),
        Some("[]"),
    );
    bind_authenticated_peers(&mut status, "local-node", &[]);
    assert_eq!(status.ports[0].physical_link, "down");
    assert_eq!(status.ports[0].peer_proof, "unknown");
}

#[test]
fn a_proven_peer_on_the_reserved_range_reports_spark_runtime_managed() {
    let sysfs = tempfile::tempdir().unwrap();
    let missing_netplan = sysfs.path().join("missing-netplan");
    interface(sysfs.path(), "ibp5s0", "p0", "1", "200000");
    let addresses = r#"[{"ifname":"ibp5s0","addr_info":[{"family":"inet","local":"172.31.252.1","prefixlen":30}]}]"#;
    let mut status = observe_filesystem(
        sysfs.path(),
        &missing_netplan,
        "2026-08-31T12:00:00Z",
        Some(addresses),
        Some("[]"),
    );
    let port_id = status.ports[0].port_id.clone();
    bind_authenticated_peers(
        &mut status,
        "local-node",
        &[link("local-node", &port_id, "peer-node")],
    );
    assert_eq!(status.ports[0].peer_proof, "authenticated_node");
    assert_eq!(status.configuration_owner, "spark_runtime_managed");
}

#[test]
fn a_proven_peer_on_an_owner_chosen_range_stays_externally_configured() {
    let sysfs = tempfile::tempdir().unwrap();
    let missing_netplan = sysfs.path().join("missing-netplan");
    interface(sysfs.path(), "ibp5s0", "p0", "1", "200000");
    let addresses = r#"[{"ifname":"ibp5s0","addr_info":[{"family":"inet","local":"10.253.0.1","prefixlen":30}]}]"#;
    let mut status = observe_filesystem(
        sysfs.path(),
        &missing_netplan,
        "2026-08-31T12:00:00Z",
        Some(addresses),
        Some("[]"),
    );
    let port_id = status.ports[0].port_id.clone();
    bind_authenticated_peers(
        &mut status,
        "local-node",
        &[link("local-node", &port_id, "peer-node")],
    );
    assert_eq!(status.ports[0].peer_proof, "authenticated_node");
    assert_eq!(status.configuration_owner, EXTERNALLY_CONFIGURED);
}

#[test]
fn netplan_provenance_never_follows_a_symlink() {
    let sysfs = tempfile::tempdir().unwrap();
    let netplan = tempfile::tempdir().unwrap();
    let outside = tempfile::NamedTempFile::new().unwrap();
    interface(sysfs.path(), "ibp5s0", "p0", "1", "200000");
    std::fs::write(
        outside.path(),
        "network:\n  ethernets:\n    ibp5s0:\n      addresses: [10.20.0.1/24]\n",
    )
    .unwrap();
    std::os::unix::fs::symlink(outside.path(), netplan.path().join("90-outside.yaml")).unwrap();

    let status = observe_filesystem(
        sysfs.path(),
        netplan.path(),
        "2026-08-31T12:00:00Z",
        Some("[]"),
        Some("[]"),
    );

    assert!(status.netplan_sources.is_empty());
    assert_eq!(status.configuration_owner, "unconfigured");
}

#[tokio::test]
async fn missing_sysfs_reports_unavailable_instead_of_an_empty_healthy_fabric() {
    let provider =
        SysfsFabricStatusProvider::with_roots("/path/that/does/not/exist", "/another/missing/path");
    let status = provider.observe("2026-08-31T12:00:00Z").await;
    assert!(!status.available);
    assert!(status.ports.is_empty());
    assert_eq!(status.configuration_owner, "unconfigured");
}
