#[test]
fn foreign_container_collision_fails_exact_ownership_check() {
    let expected = HashMap::from([
        ("spark.owner".into(), CLUSTER_OWNER.into()),
        ("spark.cluster-id".into(), Uuid::from_u128(1).to_string()),
    ]);
    let evidence = ContainerEvidence {
        labels: HashMap::from([
            ("spark.owner".into(), "foreign".into()),
            ("spark.cluster-id".into(), Uuid::from_u128(1).to_string()),
        ]),
        image: IMAGE_A.into(),
        running: true,
        status: "running".into(),
    };
    assert!(require_exact_container(&evidence, &expected, IMAGE_A, "cluster launch").is_err());
}
