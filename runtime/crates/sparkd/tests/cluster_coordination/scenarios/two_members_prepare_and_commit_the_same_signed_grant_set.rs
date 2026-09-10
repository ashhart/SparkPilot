#[test]
fn two_members_prepare_and_commit_the_same_signed_grant_set() {
    let (first, second, owner, _, now) = pair();
    let proposal = proposal(&first, &second, owner, now);
    let first_grant = first.service.prepare(&proposal, owner, now).unwrap();
    let second_grant = second.service.prepare(&proposal, owner, now).unwrap();
    let grants = vec![first_grant, second_grant];
    first.service.activate(&proposal, now).unwrap();
    second.service.activate(&proposal, now).unwrap();
    let proofs = vec![
        first.service.prove(&proposal, now).unwrap(),
        second.service.prove(&proposal, now).unwrap(),
    ];
    let collectives = vec![
        first.service.run_collective(&proposal, now).unwrap(),
        second.service.run_collective(&proposal, now).unwrap(),
    ];
    let first_receipt = first
        .service
        .commit(&proposal, &grants, &proofs, &collectives, now)
        .unwrap();
    let second_receipt = second
        .service
        .commit(&proposal, &grants, &proofs, &collectives, now)
        .unwrap();
    let receipts = vec![first_receipt, second_receipt];
    let first_status = first.service.finalize(&proposal, &receipts, now).unwrap();
    let second_status = second.service.finalize(&proposal, &receipts, now).unwrap();
    assert_eq!(first_status, second_status);
    assert_eq!(first_status.state, "ready");
    assert_eq!(first_status.members.len(), 2);
    for fixture in [&first, &second] {
        let grant_count: i64 = fixture
            .database
            .lock()
            .query_row("SELECT COUNT(*) FROM cluster_device_grants", [], |row| {
                row.get(0)
            })
            .unwrap();
        assert_eq!(grant_count, 2, "each Spark retains every member grant");
        let proof_count: i64 = fixture
            .database
            .lock()
            .query_row("SELECT COUNT(*) FROM cluster_link_proofs", [], |row| {
                row.get(0)
            })
            .unwrap();
        assert_eq!(proof_count, 2, "each Spark retains both signed link proofs");
        assert_eq!(
            fixture.link.phases.lock().unwrap().as_slice(),
            &[
                (fixture.identity.node_id(), ClusterLinkPhase::Prepare),
                (fixture.identity.node_id(), ClusterLinkPhase::Commit),
            ]
        );
    }
}
