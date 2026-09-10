#[test]
fn app_exit_between_member_commits_expires_to_standalone_on_both_nodes() {
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
    first
        .service
        .commit(&proposal, &grants, &proofs, &collectives, now)
        .unwrap();

    let expired = now + time::Duration::minutes(6);
    assert_eq!(
        first
            .service
            .reconcile_expired_transactions_once(expired)
            .unwrap(),
        1
    );
    assert_eq!(
        second
            .service
            .reconcile_expired_transactions_once(expired)
            .unwrap(),
        1
    );
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
