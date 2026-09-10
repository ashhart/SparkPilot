#[test]
fn one_cluster_refuses_a_second_active_launch_id() {
    let (first, second, owner, _, now) = pair();
    let proposal = proposal(&first, &second, owner, now);
    let grants = vec![
        first.service.prepare(&proposal, owner, now).unwrap(),
        second.service.prepare(&proposal, owner, now).unwrap(),
    ];
    ready_pair(&first, &second, &proposal, &grants, now);
    let first_launch = Uuid::new_v4();
    let second_launch = Uuid::new_v4();
    first
        .service
        .start_local_launch(
            proposal.cluster_id,
            first_launch,
            &execution_spec(first_launch),
        )
        .unwrap();

    assert!(matches!(
        first.service.start_local_launch(
            proposal.cluster_id,
            second_launch,
            &execution_spec(second_launch),
        ),
        Err(CoordinationError::Conflict(_))
    ));
    assert_eq!(first.runtime.starts.lock().unwrap().len(), 1);
}
