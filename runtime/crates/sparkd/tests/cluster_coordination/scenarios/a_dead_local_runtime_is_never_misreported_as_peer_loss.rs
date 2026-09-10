#[test]
fn a_dead_local_runtime_is_never_misreported_as_peer_loss() {
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
    let link_proofs_before = *first.link.proof_calls.lock().unwrap();
    *first.runtime.fail_health.lock().unwrap() = true;

    for expected in [1, 2] {
        assert_eq!(
            first.service.monitor_committed_link_once().unwrap(),
            ClusterMonitorOutcome::Degraded {
                consecutive_failures: expected
            }
        );
    }
    assert_eq!(
        first.service.monitor_committed_link_once().unwrap(),
        ClusterMonitorOutcome::LocalRuntimeStopped
    );
    assert_eq!(
        first.runtime.stops.lock().unwrap().as_slice(),
        &[(proposal.cluster_id, launch_id)]
    );
    assert_eq!(
        *first.link.proof_calls.lock().unwrap(),
        link_proofs_before,
        "a healthy carrier cannot hide a dead Ray worker"
    );
    let cluster_state: String = first
        .database
        .lock()
        .query_row("SELECT state FROM cluster_state", [], |row| row.get(0))
        .unwrap();
    assert_eq!(cluster_state, "degraded");
    let launch_failure: String = first
        .database
        .lock()
        .query_row("SELECT failure_code FROM cluster_launches", [], |row| {
            row.get(0)
        })
        .unwrap();
    assert_eq!(launch_failure, "LOCAL_RUNTIME_UNHEALTHY");
}
