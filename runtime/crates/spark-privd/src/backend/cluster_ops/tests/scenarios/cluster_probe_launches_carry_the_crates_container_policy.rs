/// Every probe must enforce the container capability policy and refuse implicit image pulls.
#[test]
fn cluster_probe_launches_carry_the_crates_container_policy() {
    let collective = collective_test_argv("/usr/bin/docker", IMAGE_A);
    for required in [
        "--pull=never",
        "--cap-drop=ALL",
        "--security-opt=no-new-privileges:true",
        "--read-only",
    ] {
        assert!(
            collective.iter().any(|arg| arg == required),
            "collective probe is missing {required}: {collective:?}"
        );
    }

    let transaction_id = Uuid::from_u128(11);
    let command = TwoRankCommand {
        transaction_id,
        cluster_id: Uuid::from_u128(12),
        local_node_id: Uuid::from_u128(13),
        coordinator_address: Ipv4Addr::new(172, 31, 252, 1),
        node_rank: 0,
        image_digest: IMAGE_A,
        fabric_interface: "cx7",
    };
    let two_rank = two_rank_collective_argv("/usr/bin/docker", &command);
    for required in [
        "--pull=never",
        "--cap-drop=ALL",
        "--security-opt=no-new-privileges:true",
    ] {
        assert!(
            two_rank.iter().any(|arg| arg == required),
            "two-rank probe is missing {required}: {two_rank:?}"
        );
    }
}
