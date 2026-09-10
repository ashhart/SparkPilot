#[test]
fn expired_prepared_proposal_cannot_activate_its_link() {
    let (first, second, owner, _, now) = pair();
    let proposal = proposal(&first, &second, owner, now);
    first.service.prepare(&proposal, owner, now).unwrap();

    assert!(matches!(
        first
            .service
            .activate(&proposal, now + time::Duration::minutes(6)),
        Err(CoordinationError::InvalidProposal(_))
    ));
    assert_eq!(
        first.link.phases.lock().unwrap().as_slice(),
        &[(first.identity.node_id(), ClusterLinkPhase::Prepare)]
    );
}
