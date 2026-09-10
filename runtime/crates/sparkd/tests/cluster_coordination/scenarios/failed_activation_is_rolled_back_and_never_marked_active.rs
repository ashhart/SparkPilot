#[test]
fn failed_activation_is_rolled_back_and_never_marked_active() {
    let (first, second, owner, _, now) = pair();
    let proposal = proposal(&first, &second, owner, now);
    first.service.prepare(&proposal, owner, now).unwrap();
    *first.link.fail_on.lock().unwrap() = Some(ClusterLinkPhase::Commit);

    assert!(matches!(
        first.service.activate(&proposal, now),
        Err(CoordinationError::Link(_))
    ));
    assert_eq!(
        first.link.phases.lock().unwrap().as_slice(),
        &[
            (first.identity.node_id(), ClusterLinkPhase::Prepare),
            (first.identity.node_id(), ClusterLinkPhase::Commit),
            (first.identity.node_id(), ClusterLinkPhase::Rollback),
        ]
    );
    let state: String = first
        .database
        .lock()
        .query_row("SELECT state FROM cluster_transactions", [], |row| {
            row.get(0)
        })
        .unwrap();
    assert_eq!(state, "prepared");
}
