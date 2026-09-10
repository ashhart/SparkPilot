#[test]
fn worker_loss_stops_distributed_work_but_retains_cluster_evidence() {
    let (first, second, owner, _, now) = pair();
    let proposal = proposal(&first, &second, owner, now);
    let grants = vec![
        first.service.prepare(&proposal, owner, now).unwrap(),
        second.service.prepare(&proposal, owner, now).unwrap(),
    ];
    ready_pair(&first, &second, &proposal, &grants, now);
    let launch_id = Uuid::new_v4();
    first
        .service
        .start_local_launch(proposal.cluster_id, launch_id, &execution_spec(launch_id))
        .unwrap();
    let request_failure = first.service.launch_failure_receiver(launch_id);

    let loss = first
        .service
        .handle_peer_loss(proposal.cluster_id, second.identity.node_id())
        .unwrap();

    assert_eq!(loss, ClusterPeerLoss::Worker);
    assert_eq!(*request_failure.borrow(), Some(ClusterPeerLoss::Worker));
    assert_eq!(
        first.runtime.stops.lock().unwrap().as_slice(),
        &[(proposal.cluster_id, launch_id)]
    );
    let connection = first.database.lock();
    let cluster_state: String = connection
        .query_row("SELECT state FROM cluster_state", [], |row| row.get(0))
        .unwrap();
    let transaction_state: String = connection
        .query_row("SELECT state FROM cluster_transactions", [], |row| {
            row.get(0)
        })
        .unwrap();
    let launch: (String, String) = connection
        .query_row(
            "SELECT state,failure_code FROM cluster_launches",
            [],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .unwrap();
    assert_eq!(cluster_state, "degraded");
    assert_eq!(transaction_state, "ready");
    assert_eq!(launch, ("stopped".into(), "WORKER_LOST".into()));
    for table in [
        "cluster_members",
        "cluster_device_grants",
        "cluster_link_proofs",
        "cluster_collective_proofs",
        "cluster_commit_receipts",
    ] {
        let count: i64 = connection
            .query_row(&format!("SELECT COUNT(*) FROM {table}"), [], |row| {
                row.get(0)
            })
            .unwrap();
        assert_eq!(count, 2, "{table} survives a worker loss");
    }
    drop(connection);
    assert_ne!(
        first.link.phases.lock().unwrap().last().unwrap().1,
        ClusterLinkPhase::Rollback
    );
    let next_launch = Uuid::new_v4();
    assert!(matches!(
        first.service.start_local_launch(
            proposal.cluster_id,
            next_launch,
            &execution_spec(next_launch),
        ),
        Err(CoordinationError::Conflict(_))
    ));
}
