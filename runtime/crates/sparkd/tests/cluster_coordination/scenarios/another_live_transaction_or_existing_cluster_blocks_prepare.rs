#[test]
fn another_live_transaction_or_existing_cluster_blocks_prepare() {
    let (first, second, owner, _, now) = pair();
    let original = proposal(&first, &second, owner, now);
    let grants = vec![
        first.service.prepare(&original, owner, now).unwrap(),
        second.service.prepare(&original, owner, now).unwrap(),
    ];
    let competing = proposal(&first, &second, owner, now);
    assert!(matches!(
        first.service.prepare(&competing, owner, now),
        Err(CoordinationError::Conflict(_))
    ));
    ready_pair(&first, &second, &original, &grants, now);
    assert!(matches!(
        first.service.prepare(&competing, owner, now),
        Err(CoordinationError::Conflict(_))
    ));
}
