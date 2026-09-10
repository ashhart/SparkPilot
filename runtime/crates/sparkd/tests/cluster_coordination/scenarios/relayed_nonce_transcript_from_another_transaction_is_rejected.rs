#[test]
fn relayed_nonce_transcript_from_another_transaction_is_rejected() {
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
    let mut collectives = vec![
        first.service.run_collective(&proposal, now).unwrap(),
        second.service.run_collective(&proposal, now).unwrap(),
    ];
    let mut relayed_proposal = proposal.clone();
    relayed_proposal.transaction_id = Uuid::new_v4();
    collectives[0].fabric_authentication = Some(
        first
            .authenticator
            .authenticate(&relayed_proposal, &first.identity, now)
            .unwrap(),
    );

    let error = first
        .service
        .commit(&proposal, &grants, &proofs, &collectives, now)
        .unwrap_err();
    assert!(
        error
            .to_string()
            .contains("fabric challenge is not bound to this live proposal")
    );
    let state: String = first
        .database
        .lock()
        .query_row(
            "SELECT state FROM cluster_transactions WHERE transaction_id=?1",
            [proposal.transaction_id.to_string()],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(state, "collective");
}
