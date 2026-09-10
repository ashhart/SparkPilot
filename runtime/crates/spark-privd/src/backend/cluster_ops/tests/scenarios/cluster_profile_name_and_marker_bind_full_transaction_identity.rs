#[test]
fn cluster_profile_name_and_marker_bind_full_transaction_identity() {
    let cluster = Uuid::from_u128(1);
    let transaction = Uuid::from_u128(2);
    let name = cluster_link_profile(cluster, transaction);
    assert_eq!(
        name,
        format!(
            "SparkPilot-CX7-{}-{}",
            cluster.simple(),
            transaction.simple()
        )
    );
    let marker_a = cluster_link_owner_marker(
        transaction,
        cluster,
        Uuid::from_u128(3),
        Uuid::from_u128(4),
        Ipv4Addr::new(172, 31, 252, 1),
        Ipv4Addr::new(172, 31, 252, 2),
    );
    let marker_b = cluster_link_owner_marker(
        transaction,
        cluster,
        Uuid::from_u128(3),
        Uuid::from_u128(5),
        Ipv4Addr::new(172, 31, 252, 1),
        Ipv4Addr::new(172, 31, 252, 2),
    );
    assert_ne!(marker_a, marker_b);
}
