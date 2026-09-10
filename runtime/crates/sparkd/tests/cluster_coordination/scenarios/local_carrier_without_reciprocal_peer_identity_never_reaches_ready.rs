#[test]
fn local_carrier_without_reciprocal_peer_identity_never_reaches_ready() {
    let (first, second, owner, _, now) = pair();
    let proposal = proposal(&first, &second, owner, now);
    let grants = vec![
        first.service.prepare(&proposal, owner, now).unwrap(),
        second.service.prepare(&proposal, owner, now).unwrap(),
    ];
    first.service.activate(&proposal, now).unwrap();
    second.service.activate(&proposal, now).unwrap();
    *second.link.neighbour_override.lock().unwrap() = Some("02:ff:ff:ff:ff:ff".into());
    let proofs = vec![
        first.service.prove(&proposal, now).unwrap(),
        second.service.prove(&proposal, now).unwrap(),
    ];
    let collectives = vec![
        first.service.run_collective(&proposal, now).unwrap(),
        second.service.run_collective(&proposal, now).unwrap(),
    ];

    assert!(matches!(
        first
            .service
            .commit(&proposal, &grants, &proofs, &collectives, now),
        Err(CoordinationError::InvalidGrant(_))
    ));
    let cluster_count: i64 = first
        .database
        .lock()
        .query_row("SELECT COUNT(*) FROM cluster_state", [], |row| row.get(0))
        .unwrap();
    assert_eq!(cluster_count, 0);
}
