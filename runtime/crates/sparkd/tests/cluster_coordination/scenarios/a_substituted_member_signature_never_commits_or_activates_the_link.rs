#[test]
fn a_substituted_member_signature_never_commits_or_activates_the_link() {
    let (first, second, owner, _, now) = pair();
    let proposal = proposal(&first, &second, owner, now);
    let first_grant = first.service.prepare(&proposal, owner, now).unwrap();
    let mut second_grant = second.service.prepare(&proposal, owner, now).unwrap();
    second_grant.authority_signature.replace_range(..1, "A");

    let error = first
        .service
        .commit(&proposal, &[first_grant, second_grant], &[], &[], now)
        .unwrap_err();
    assert!(matches!(error, CoordinationError::InvalidGrant(_)));
    assert_eq!(
        first.link.phases.lock().unwrap().as_slice(),
        &[(first.identity.node_id(), ClusterLinkPhase::Prepare)]
    );
    let cluster_count: i64 = first
        .database
        .lock()
        .query_row("SELECT COUNT(*) FROM cluster_state", [], |row| row.get(0))
        .unwrap();
    assert_eq!(cluster_count, 0);
}
