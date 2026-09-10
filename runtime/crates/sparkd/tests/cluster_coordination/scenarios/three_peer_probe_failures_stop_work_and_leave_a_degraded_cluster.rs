#[test]
fn three_peer_probe_failures_stop_work_and_leave_a_degraded_cluster() {
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
    *first.link.fail_proof.lock().unwrap() = true;

    assert_eq!(
        first.service.monitor_committed_link_once().unwrap(),
        ClusterMonitorOutcome::Degraded {
            consecutive_failures: 1
        }
    );
    assert_eq!(
        first.service.monitor_committed_link_once().unwrap(),
        ClusterMonitorOutcome::Degraded {
            consecutive_failures: 2
        }
    );
    assert_eq!(
        first.service.monitor_committed_link_once().unwrap(),
        ClusterMonitorOutcome::DistributedWorkStopped {
            peer: ClusterPeerLoss::Worker
        }
    );
    assert_eq!(
        first.runtime.stops.lock().unwrap().as_slice(),
        &[(proposal.cluster_id, launch_id)]
    );
    let cluster_state: String = first
        .database
        .lock()
        .query_row("SELECT state FROM cluster_state", [], |row| row.get(0))
        .unwrap();
    assert_eq!(cluster_state, "degraded");
}
