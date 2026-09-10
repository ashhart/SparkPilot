#[test]
fn coordinator_loss_requires_promotion_and_never_destroys_membership() {
    let (first, second, owner, _, now) = pair();
    let proposal = proposal(&first, &second, owner, now);
    let grants = vec![
        first.service.prepare(&proposal, owner, now).unwrap(),
        second.service.prepare(&proposal, owner, now).unwrap(),
    ];
    ready_pair(&first, &second, &proposal, &grants, now);
    let launch_id = Uuid::new_v4();
    second
        .service
        .start_local_launch(proposal.cluster_id, launch_id, &execution_spec(launch_id))
        .unwrap();
    let request_failure = second.service.launch_failure_receiver(launch_id);

    let loss = second
        .service
        .handle_peer_loss(proposal.cluster_id, first.identity.node_id())
        .unwrap();

    assert_eq!(loss, ClusterPeerLoss::Coordinator);
    assert_eq!(
        *request_failure.borrow(),
        Some(ClusterPeerLoss::Coordinator)
    );
    let connection = second.database.lock();
    let state: String = connection
        .query_row("SELECT state FROM cluster_state", [], |row| row.get(0))
        .unwrap();
    let launch: (String, String) = connection
        .query_row(
            "SELECT state,failure_code FROM cluster_launches",
            [],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .unwrap();
    let member_count: i64 = connection
        .query_row("SELECT COUNT(*) FROM cluster_members", [], |row| row.get(0))
        .unwrap();
    assert_eq!(state, "degraded");
    assert_eq!(
        launch,
        (
            "stopped".into(),
            "COORDINATOR_LOST_PROMOTION_REQUIRED".into()
        )
    );
    assert_eq!(member_count, 2);
    drop(connection);
    assert_ne!(
        second.link.phases.lock().unwrap().last().unwrap().1,
        ClusterLinkPhase::Rollback
    );
}
