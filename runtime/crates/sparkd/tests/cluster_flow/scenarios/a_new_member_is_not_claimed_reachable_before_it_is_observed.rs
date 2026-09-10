/// Record new worker membership as unobserved until health aggregation proves reachability; creation itself contacts no peer.
#[tokio::test]
async fn a_new_member_is_not_claimed_reachable_before_it_is_observed() {
    let (state, client, database, _guard) =
        test_state("owner", healthy_report(), CollectiveOutcome::Passed);
    let coordinator = state.identity.node_id().to_string();
    let peer = uuid::Uuid::new_v4().to_string();
    let ids = vec![coordinator.clone(), peer.clone()];
    record_peer_facts(&database, &facts_for(&ids, "auth-1", "0.1.0"));

    let (status, value) = send(
        state.clone(),
        signed_request(
            &client,
            "POST",
            "/api/v1/cluster/create",
            Some(&create_body(&ids)),
        ),
    )
    .await;
    assert_eq!(status, StatusCode::ACCEPTED);
    assert_eq!(
        wait_for_operation(&database, value["id"].as_str().unwrap()),
        "succeeded"
    );

    let (_, cluster) = send(
        state.clone(),
        signed_request(&client, "GET", "/api/v1/cluster", None),
    )
    .await;
    let members = cluster["members"].as_array().unwrap();
    let reachability = |node_id: &str| {
        members
            .iter()
            .find(|member| member["node_id"] == node_id)
            .unwrap()["reachable"]
            .as_bool()
            .unwrap()
    };
    assert!(reachability(&coordinator), "the coordinator is this node");
    assert!(
        !reachability(&peer),
        "an uncontacted peer must not be published as reachable"
    );
}
