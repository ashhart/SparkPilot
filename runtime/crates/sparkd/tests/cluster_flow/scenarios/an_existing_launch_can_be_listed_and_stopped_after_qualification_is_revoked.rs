#[tokio::test]
async fn an_existing_launch_can_be_listed_and_stopped_after_qualification_is_revoked() {
    let (state, client, database, _guard) =
        test_state("owner", healthy_report(), CollectiveOutcome::Passed);
    let runtime = Arc::new(RecordingDistributedRuntime::default());
    let coordinator = Arc::new(ClusterCoordinationService::new(
        database.clone(),
        state.identity.clone(),
        Arc::new(TransactionLinkBoundary),
        runtime.clone(),
    ));
    let cluster_id = uuid::Uuid::new_v4();
    let launch_id = uuid::Uuid::new_v4();
    let coordinator_node_id = state.identity.node_id();
    let worker_node_id = uuid::Uuid::new_v4();
    database
        .lock()
        .execute(
            "INSERT INTO cluster_launches
             (launch_id,cluster_id,recipe_id,profile_id,execution_spec_json,state,coordinator_node_id,
              worker_node_id,created_at,updated_at)
             VALUES(?1,?2,'verified-recipe','safe-profile','{}','running',?3,?4,?5,?5)",
            rusqlite::params![
                launch_id.to_string(),
                cluster_id.to_string(),
                coordinator_node_id.to_string(),
                worker_node_id.to_string(),
                "2026-09-01T12:00:00Z",
            ],
        )
        .unwrap();
    let state = state.with_cluster_coordination(coordinator);

    let (list_status, launches) = send(
        state.clone(),
        signed_request(&client, "GET", "/api/v1/cluster/launches", None),
    )
    .await;
    assert_eq!(list_status, StatusCode::OK);
    assert_eq!(launches.as_array().unwrap().len(), 1);

    let path = format!("/api/v1/cluster/launches/{launch_id}/stop");
    let (stop_status, stopped) = send(
        state,
        signed_request_with_options(
            &client,
            "POST",
            &path,
            None,
            uuid::Uuid::new_v4(),
            Some(&path),
        ),
    )
    .await;
    assert_eq!(stop_status, StatusCode::OK, "{stopped}");
    assert_eq!(stopped["state"], "stopped");
    assert_eq!(runtime.stops.lock().as_slice(), &[(cluster_id, launch_id)]);
}
