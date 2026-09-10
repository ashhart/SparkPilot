#[test]
fn an_unproven_stop_is_retried_after_restart_until_the_launch_fence_releases() {
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
    *first.runtime.fail.lock().unwrap() = true;

    assert!(matches!(
        first
            .service
            .handle_peer_loss(proposal.cluster_id, second.identity.node_id()),
        Err(CoordinationError::Runtime(_))
    ));
    let state: (String, String, String) = first
        .database
        .lock()
        .query_row(
            "SELECT c.state,l.state,l.failure_code FROM cluster_state c JOIN cluster_launches l ON l.cluster_id=c.id",
            [],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
        )
        .unwrap();
    assert_eq!(
        state,
        (
            "degraded".into(),
            "stopping".into(),
            "WORKER_LOSS_STOP_UNPROVEN".into()
        )
    );

    *first.runtime.fail.lock().unwrap() = false;
    let restarted = ClusterCoordinationService::new(
        first.database.clone(),
        first.identity.clone(),
        first.link.clone(),
        first.runtime.clone(),
    )
    .with_collective(first.collective.clone())
    .with_peer_authenticator(first.authenticator.clone())
    .with_events(first.events.clone())
    .with_runtime_version("0.1.0")
    .with_engine_image(Some(
        "vllm@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa".into(),
    ));
    assert_eq!(restarted.reconcile_stopping_launches_once().unwrap(), 1);
    assert_eq!(first.runtime.stops.lock().unwrap().len(), 2);
    assert_eq!(restarted.launch_status(launch_id).unwrap().state, "stopped");
}
