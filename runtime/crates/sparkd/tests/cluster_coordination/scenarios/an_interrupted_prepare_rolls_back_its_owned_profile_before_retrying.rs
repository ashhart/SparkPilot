#[test]
fn an_interrupted_prepare_rolls_back_its_owned_profile_before_retrying() {
    let (first, second, owner, _, now) = pair();
    let proposal = proposal(&first, &second, owner, now);
    let original = first.service.prepare(&proposal, owner, now).unwrap();
    first
        .database
        .lock()
        .execute(
            "UPDATE cluster_transactions SET state='preparing' WHERE transaction_id=?1",
            [proposal.transaction_id.to_string()],
        )
        .unwrap();

    let replay = first.service.prepare(&proposal, owner, now).unwrap();

    assert_eq!(replay, original);
    assert_eq!(
        first.link.phases.lock().unwrap().as_slice(),
        &[
            (first.identity.node_id(), ClusterLinkPhase::Prepare),
            (first.identity.node_id(), ClusterLinkPhase::Rollback),
            (first.identity.node_id(), ClusterLinkPhase::Prepare),
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
