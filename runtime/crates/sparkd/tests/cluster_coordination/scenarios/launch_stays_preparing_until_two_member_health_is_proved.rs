#[test]
fn launch_stays_preparing_until_two_member_health_is_proved() {
    let (first, second, owner, _, now) = pair();
    let proposal = proposal(&first, &second, owner, now);
    let grants = vec![
        first.service.prepare(&proposal, owner, now).unwrap(),
        second.service.prepare(&proposal, owner, now).unwrap(),
    ];
    ready_pair(&first, &second, &proposal, &grants, now);
    let launch_id = Uuid::new_v4();
    *first.runtime.fail_health.lock().unwrap() = true;

    first
        .service
        .start_local_launch(proposal.cluster_id, launch_id, &execution_spec(launch_id))
        .unwrap();
    assert_eq!(
        first.service.launch_status(launch_id).unwrap().state,
        "preparing"
    );

    *first.runtime.fail_health.lock().unwrap() = false;
    assert_eq!(
        first.service.reconcile_preparing_launches_once().unwrap(),
        1
    );
    assert_eq!(
        first.service.launch_status(launch_id).unwrap().state,
        "running"
    );
}
