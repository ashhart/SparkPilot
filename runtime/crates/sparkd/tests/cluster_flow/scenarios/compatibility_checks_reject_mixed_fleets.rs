#[test]
fn compatibility_checks_reject_mixed_fleets() {
    let ids = vec!["a".to_owned(), "b".to_owned()];
    assert!(cluster::check_authority(&facts_for(&ids, "auth-1", "0.1.0")).is_ok());

    let mixed_runtime = vec![
        cluster::MemberFacts {
            node_id: "a".into(),
            name: "A".into(),
            authority_fingerprint: "auth-1".into(),
            runtime_version: "0.1.0".into(),
            engine_image: "vllm:0.11".into(),
        },
        cluster::MemberFacts {
            node_id: "b".into(),
            name: "B".into(),
            authority_fingerprint: "auth-1".into(),
            runtime_version: "0.2.0".into(),
            engine_image: "vllm:0.11".into(),
        },
    ];
    assert!(matches!(
        cluster::check_compatibility(&mixed_runtime),
        Err(ClusterError::VersionMismatch(_))
    ));
}
