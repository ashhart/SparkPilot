#[test]
fn member_firewall_allows_only_the_exact_peer_and_blocks_lan_ports() {
    let marker = cluster_firewall_owner_marker(
        Uuid::from_u128(1),
        Uuid::from_u128(2),
        Uuid::from_u128(3),
        Uuid::from_u128(4),
        Ipv4Addr::new(172, 31, 252, 1),
        Ipv4Addr::new(172, 31, 252, 2),
        "cx7p1",
    );
    let script = firewall_install_script(
        "spc_owned",
        &marker,
        "cx7p1",
        Ipv4Addr::new(172, 31, 252, 1),
        Ipv4Addr::new(172, 31, 252, 2),
    );
    assert!(
        script.contains(
            "iifname \"cx7p1\" ip saddr 172.31.252.2 ip daddr 172.31.252.1 tcp dport"
        )
    );
    assert!(script.contains("19443"));
    assert!(script.contains("iifname \"cx7p1\" tcp dport"));
    assert!(!script.contains("iifname != \"lo\""));
    assert!(script.contains("deny-fabric-tcp-from-lan"));
    assert!(script.contains("iifname \"cx7p1\" drop"));
    assert!(!script.contains("192.168."));
    assert!(!script.contains("sh -c"));
}
