#[test]
fn an_interrupted_commit_resumes_from_its_durable_fence() {
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
        .database
        .lock()
        .execute(
            "UPDATE cluster_transactions SET state='committing' WHERE transaction_id=?1",
            [proposal.transaction_id.to_string()],
        )
        .unwrap();

    let receipt = first
        .service
        .commit(&proposal, &grants, &proofs, &collectives, now)
        .unwrap();
    assert_eq!(receipt.member_node_id, first.identity.node_id());
    let durable_state: String = first
        .database
        .lock()
        .query_row(
            "SELECT state FROM cluster_transactions WHERE transaction_id=?1",
            [proposal.transaction_id.to_string()],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(durable_state, "committed");
}
