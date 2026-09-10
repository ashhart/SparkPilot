#[test]
fn malformed_interface_and_profile_evidence_fail_closed() {
    assert!(parse_active_ethernet_devices(b"malformed\n").is_err());
    assert!(parse_default_route_devices(b"default via 192.168.1.1\n").is_err());
    let evidence = ClusterProfileEvidence {
        id: "foreign".into(),
        stable_id: "foreign".into(),
        interface: "cx7".into(),
        autoconnect: "no".into(),
        ipv4_method: "manual".into(),
        ipv4_addresses: "172.31.252.1/30".into(),
        ipv4_gateway: "".into(),
        ipv4_routes: "".into(),
        ipv4_dns: "".into(),
        ipv4_dns_search: "".into(),
        ipv4_route_table: "0".into(),
        ipv4_route_metric: "-1".into(),
        never_default: "yes".into(),
        ignore_auto_dns: "yes".into(),
        ipv6_method: "disabled".into(),
        mtu: "9000".into(),
    };
    assert!(!profile_matches(
        &evidence,
        "SparkPilot-CX7-owned",
        "owned",
        Ipv4Addr::new(172, 31, 252, 1)
    ));
}
