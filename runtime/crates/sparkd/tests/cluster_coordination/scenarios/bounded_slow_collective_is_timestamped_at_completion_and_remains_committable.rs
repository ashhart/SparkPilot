#[test]
fn bounded_slow_collective_is_timestamped_at_completion_and_remains_committable() {
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
    *first.collective.elapsed_ms.lock().unwrap() = Some(180_000);
    *second.collective.elapsed_ms.lock().unwrap() = Some(180_000);
    let collectives = vec![
        first.service.run_collective(&proposal, now).unwrap(),
        second.service.run_collective(&proposal, now).unwrap(),
    ];
    let commit_time = now + time::Duration::seconds(181);

    first
        .service
        .commit(&proposal, &grants, &proofs, &collectives, commit_time)
        .unwrap();
}
