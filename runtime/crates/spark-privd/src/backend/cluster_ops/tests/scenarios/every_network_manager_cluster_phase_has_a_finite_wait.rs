#[test]
fn every_network_manager_cluster_phase_has_a_finite_wait() {
    for phase in [
        ClusterLinkPhase::Prepare,
        ClusterLinkPhase::Commit,
        ClusterLinkPhase::Rollback,
    ] {
        let argv = cluster_link_phase_args(
            phase,
            "cx7",
            "SparkPilot-CX7-owned",
            "sparkpilot-cluster-link-owned",
            "172.31.252.1/30",
        );
        assert_eq!(
            &argv[..2],
            &["--wait".to_owned(), CLUSTER_LINK_WAIT_SECONDS.to_owned()]
        );
    }
}
