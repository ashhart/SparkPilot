#[test]
fn distributed_launch_starts_once_per_member_and_replay_is_safe() {
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
    second
        .service
        .start_local_launch(proposal.cluster_id, launch_id, &execution_spec(launch_id))
        .unwrap();
    first
        .service
        .start_local_launch(proposal.cluster_id, launch_id, &execution_spec(launch_id))
        .unwrap();

    assert_eq!(first.runtime.starts.lock().unwrap().len(), 1);
    assert_eq!(second.runtime.starts.lock().unwrap().len(), 1);
    assert_eq!(first.service.launches().unwrap().len(), 1);
    for fixture in [&first, &second] {
        let state: String = fixture
            .database
            .lock()
            .query_row("SELECT state FROM cluster_launches", [], |row| row.get(0))
            .unwrap();
        assert_eq!(state, "running");
    }

    first.service.stop_local_launch(launch_id).unwrap();
    first.service.stop_local_launch(launch_id).unwrap();
    assert_eq!(first.runtime.stops.lock().unwrap().len(), 1);
    assert_eq!(
        first.service.launch_status(launch_id).unwrap().state,
        "stopped"
    );
}
