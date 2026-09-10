#[test]
fn measured_latency_and_bandwidth_are_required_before_commit() {
    let (first, second, owner, _, now) = pair();
    let proposal = proposal(&first, &second, owner, now);
    first.service.prepare(&proposal, owner, now).unwrap();
    first.service.activate(&proposal, now).unwrap();
    first.service.prove(&proposal, now).unwrap();

    *first.collective.bandwidth_mbps.lock().unwrap() = Some(9_999);
    assert!(matches!(
        first.service.run_collective(&proposal, now),
        Err(CoordinationError::InvalidGrant(_))
    ));
    *first.collective.bandwidth_mbps.lock().unwrap() = Some(100_000);
    *first.collective.latency_us.lock().unwrap() = Some(5_001);
    assert!(matches!(
        first.service.run_collective(&proposal, now),
        Err(CoordinationError::InvalidGrant(_))
    ));
}
