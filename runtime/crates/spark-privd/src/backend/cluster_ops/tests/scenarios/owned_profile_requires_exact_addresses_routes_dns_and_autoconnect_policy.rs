#[test]
fn owned_profile_requires_exact_addresses_routes_dns_and_autoconnect_policy() {
    let expected = ClusterProfileEvidence {
        id: "SparkPilot-CX7-owned".into(),
        stable_id: "owned".into(),
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
    let matches = |evidence: &ClusterProfileEvidence| {
        profile_matches(
            evidence,
            "SparkPilot-CX7-owned",
            "owned",
            Ipv4Addr::new(172, 31, 252, 1),
        )
    };
    assert!(matches(&expected));

    let mut mutations = Vec::new();
    let mut changed = expected.clone();
    changed.autoconnect = "yes".into();
    mutations.push(("autoconnect", changed));
    let mut changed = expected.clone();
    changed.ipv4_addresses = "172.31.252.1/30,192.168.1.20/24".into();
    mutations.push(("extra address", changed));
    let mut changed = expected.clone();
    changed.ipv4_gateway = "192.168.1.1".into();
    mutations.push(("gateway", changed));
    let mut changed = expected.clone();
    changed.ipv4_routes = "10.0.0.0/8 172.31.252.2".into();
    mutations.push(("route", changed));
    let mut changed = expected.clone();
    changed.ipv4_dns = "1.1.1.1".into();
    mutations.push(("dns", changed));
    let mut changed = expected.clone();
    changed.ipv4_dns_search = "example.test".into();
    mutations.push(("dns search", changed));
    let mut changed = expected.clone();
    changed.ipv4_route_table = "254".into();
    mutations.push(("route table", changed));
    let mut changed = expected;
    changed.ipv4_route_metric = "100".into();
    mutations.push(("route metric", changed));

    for (name, mutation) in mutations {
        assert!(!matches(&mutation), "accepted changed {name}");
    }
}
