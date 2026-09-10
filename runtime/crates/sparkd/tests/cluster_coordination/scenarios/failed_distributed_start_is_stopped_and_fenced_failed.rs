#[test]
fn failed_distributed_start_is_stopped_and_fenced_failed() {
    let (first, second, owner, _, now) = pair();
    let proposal = proposal(&first, &second, owner, now);
    let grants = vec![
        first.service.prepare(&proposal, owner, now).unwrap(),
        second.service.prepare(&proposal, owner, now).unwrap(),
    ];
    ready_pair(&first, &second, &proposal, &grants, now);
    let launch_id = Uuid::new_v4();
    *first.runtime.fail_start.lock().unwrap() = true;

    assert!(matches!(
        first.service.start_local_launch(
            proposal.cluster_id,
            launch_id,
            &execution_spec(launch_id)
        ),
        Err(CoordinationError::Runtime(_))
    ));
    assert_eq!(
        first.runtime.stops.lock().unwrap().as_slice(),
        &[(proposal.cluster_id, launch_id)]
    );
    let row: (String, String) = first
        .database
        .lock()
        .query_row(
            "SELECT state,failure_code FROM cluster_launches",
            [],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .unwrap();
    assert_eq!(row, ("failed".into(), "START_FAILED".into()));
}
