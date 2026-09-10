#[test]
fn every_side_effecting_phase_is_idempotent() {
    let (first, second, owner, _, now) = pair();
    let proposal = proposal(&first, &second, owner, now);
    first.service.prepare(&proposal, owner, now).unwrap();

    first.service.activate(&proposal, now).unwrap();
    first.service.activate(&proposal, now).unwrap();
    let proof = first.service.prove(&proposal, now).unwrap();
    let proof_replay = first.service.prove(&proposal, now).unwrap();
    let collective = first.service.run_collective(&proposal, now).unwrap();
    let collective_replay = first.service.run_collective(&proposal, now).unwrap();

    assert_eq!(proof, proof_replay);
    assert_eq!(collective, collective_replay);
    let retained_fabric_authentication: i64 = first
        .database
        .lock()
        .query_row(
            "SELECT COUNT(*) FROM cluster_transactions WHERE fabric_auth_json IS NOT NULL",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(retained_fabric_authentication, 1);
    assert_eq!(*first.link.proof_calls.lock().unwrap(), 1);
    assert_eq!(*first.collective.calls.lock().unwrap(), 1);
    assert_eq!(
        first.link.phases.lock().unwrap().as_slice(),
        &[
            (first.identity.node_id(), ClusterLinkPhase::Prepare),
            (first.identity.node_id(), ClusterLinkPhase::Commit),
        ]
    );
}
