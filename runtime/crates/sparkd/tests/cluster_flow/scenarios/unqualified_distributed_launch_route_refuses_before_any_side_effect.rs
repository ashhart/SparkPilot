#[tokio::test]
async fn unqualified_distributed_launch_route_refuses_before_any_side_effect() {
    let (state, client, database, _guard) =
        test_state("owner", healthy_report(), CollectiveOutcome::Passed);
    let coordinator = Arc::new(ClusterCoordinationService::new(
        database.clone(),
        state.identity.clone(),
        Arc::new(TransactionLinkBoundary),
        Arc::new(NoDistributedRuntime),
    ));
    let body = json!({
        "cluster_id": uuid::Uuid::new_v4(),
        "launch_id": uuid::Uuid::new_v4(),
        "recipe_id": "verified-recipe",
        "profile_id": "safe-profile",
    });

    let (status, value) = send(
        state.with_cluster_coordination(coordinator),
        signed_request(&client, "POST", "/api/v1/cluster/launches", Some(&body)),
    )
    .await;

    assert_eq!(status, StatusCode::SERVICE_UNAVAILABLE);
    assert_eq!(value["error"]["code"], "CLUSTER_INFERENCE_UNAVAILABLE");
    let connection = database.lock();
    let launches: i64 = connection
        .query_row("SELECT COUNT(*) FROM cluster_launches", [], |row| {
            row.get(0)
        })
        .unwrap();
    let refusal: String = connection
        .query_row(
            "SELECT result FROM audit_records WHERE action='cluster.launch.start'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(launches, 0);
    assert_eq!(refusal, "refused");
}
