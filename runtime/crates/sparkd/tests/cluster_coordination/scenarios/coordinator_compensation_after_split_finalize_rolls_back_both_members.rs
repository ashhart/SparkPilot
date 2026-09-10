#[test]
fn coordinator_compensation_after_split_finalize_rolls_back_both_members() {
    let (first, second, owner, _, now) = pair();
    let proposal = proposal(&first, &second, owner, now);
    let grants = vec![
        first.service.prepare(&proposal, owner, now).unwrap(),
        second.service.prepare(&proposal, owner, now).unwrap(),
    ];
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
    let receipts = vec![
        first
            .service
            .commit(&proposal, &grants, &proofs, &collectives, now)
            .unwrap(),
        second
            .service
            .commit(&proposal, &grants, &proofs, &collectives, now)
            .unwrap(),
    ];
    first.service.finalize(&proposal, &receipts, now).unwrap();

    assert_eq!(
        second
            .service
            .reconcile_expired_transactions_once(now + time::Duration::minutes(6))
            .unwrap(),
        1
    );
    first.service.rollback(&proposal).unwrap();
    for fixture in [&first, &second] {
        let connection = fixture.database.lock();
        let state: String = connection
            .query_row("SELECT state FROM cluster_transactions", [], |row| {
                row.get(0)
            })
            .unwrap();
        let membership: i64 = connection
            .query_row("SELECT COUNT(*) FROM cluster_state", [], |row| row.get(0))
            .unwrap();
        assert_eq!(state, "rolled_back");
        assert_eq!(membership, 0);
    }
}
