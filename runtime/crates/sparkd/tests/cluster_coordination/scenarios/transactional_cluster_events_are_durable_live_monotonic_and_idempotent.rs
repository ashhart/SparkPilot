#[test]
fn transactional_cluster_events_are_durable_live_monotonic_and_idempotent() {
    let (first, second, owner, _, now) = pair();
    let mut live = first.events.subscribe();
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

    let durable = cluster_events(&first.database);
    assert_eq!(
        durable
            .iter()
            .map(|(_, event_type)| event_type.as_str())
            .collect::<Vec<_>>(),
        [
            "cluster.link.changed",
            "cluster.validation.progress",
            "cluster.validation.progress",
            "cluster.node.joined",
            "cluster.ready",
        ]
    );
    assert_eq!(
        durable
            .iter()
            .map(|(sequence, _)| *sequence)
            .collect::<Vec<_>>(),
        (1..=5).collect::<Vec<_>>()
    );
    let live_events = std::iter::from_fn(|| live.try_recv().ok()).collect::<Vec<_>>();
    assert_eq!(live_events.len(), durable.len());
    assert_eq!(
        live_events
            .iter()
            .map(|event| event["sequence"].as_i64().unwrap())
            .collect::<Vec<_>>(),
        (1..=5).collect::<Vec<_>>()
    );

    first.service.activate(&proposal, now).unwrap();
    first.service.prove(&proposal, now).unwrap();
    first.service.run_collective(&proposal, now).unwrap();
    first
        .service
        .commit(&proposal, &grants, &proofs, &collectives, now)
        .unwrap();
    first.service.finalize(&proposal, &receipts, now).unwrap();
    assert_eq!(cluster_events(&first.database), durable);
    assert!(live.try_recv().is_err());

    *first.link.fail_proof.lock().unwrap() = true;
    assert!(matches!(
        first.service.monitor_committed_link_once().unwrap(),
        ClusterMonitorOutcome::Degraded {
            consecutive_failures: 1
        }
    ));
    assert!(matches!(
        first.service.monitor_committed_link_once().unwrap(),
        ClusterMonitorOutcome::Degraded {
            consecutive_failures: 2
        }
    ));
    assert!(matches!(
        first.service.monitor_committed_link_once().unwrap(),
        ClusterMonitorOutcome::DistributedWorkStopped {
            peer: ClusterPeerLoss::Worker
        }
    ));
    let degraded = cluster_events(&first.database);
    assert_eq!(
        degraded
            .iter()
            .map(|(sequence, _)| *sequence)
            .collect::<Vec<_>>(),
        (1..=8).collect::<Vec<_>>()
    );
    assert_eq!(
        degraded[5..]
            .iter()
            .map(|(_, event_type)| event_type.as_str())
            .collect::<Vec<_>>(),
        [
            "cluster.link.changed",
            "cluster.degraded",
            "cluster.degraded"
        ]
    );
    assert!(matches!(
        first.service.monitor_committed_link_once().unwrap(),
        ClusterMonitorOutcome::DistributedWorkStopped {
            peer: ClusterPeerLoss::Worker
        }
    ));
    assert_eq!(cluster_events(&first.database), degraded);

    *first.link.fail_proof.lock().unwrap() = false;
    assert_eq!(
        first.service.monitor_committed_link_once().unwrap(),
        ClusterMonitorOutcome::Healthy
    );
    let recovered = cluster_events(&first.database);
    assert_eq!(
        recovered[8..]
            .iter()
            .map(|(_, event_type)| event_type.as_str())
            .collect::<Vec<_>>(),
        ["cluster.link.changed", "cluster.ready"]
    );
    assert_eq!(
        recovered
            .iter()
            .map(|(sequence, _)| *sequence)
            .collect::<Vec<_>>(),
        (1..=10).collect::<Vec<_>>()
    );
    assert_eq!(
        first.service.monitor_committed_link_once().unwrap(),
        ClusterMonitorOutcome::Healthy
    );
    assert_eq!(cluster_events(&first.database), recovered);
}
