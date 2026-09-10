#[test]
fn incomplete_or_duplicate_collective_evidence_never_reaches_ready() {
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
    let first_collective = first.service.run_collective(&proposal, now).unwrap();
    let second_collective = second.service.run_collective(&proposal, now).unwrap();

    assert!(matches!(
        first.service.commit(
            &proposal,
            &grants,
            &proofs,
            std::slice::from_ref(&first_collective),
            now
        ),
        Err(CoordinationError::InvalidGrant(_))
    ));
    assert!(matches!(
        first.service.commit(
            &proposal,
            &grants,
            &proofs,
            &[first_collective.clone(), first_collective],
            now,
        ),
        Err(CoordinationError::InvalidGrant(_))
    ));
    first
        .service
        .commit(
            &proposal,
            &grants,
            &proofs,
            &[
                second_collective,
                first.service.run_collective(&proposal, now).unwrap(),
            ],
            now,
        )
        .unwrap();
}
