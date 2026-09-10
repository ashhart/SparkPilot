#[tokio::test]
async fn service_principal_uses_only_its_owner_granted_deployment_and_revocation_cancels_leases() {
    let source = node().await;
    let destination = node_with_model(true).await;
    let principal = enroll(&source, &destination).await;
    let (status, snapshot) = destination
        .call(
            "GET",
            &format!("{BASE}/node-capabilities"),
            None,
            None,
            false,
        )
        .await;
    assert_eq!(status, StatusCode::OK, "{snapshot}");
    let deployment = snapshot["deployments"][0]["deployment_id"]
        .as_str()
        .unwrap();
    let policy = json!({"pool_id":Uuid::new_v4(),"display_name":"Approved local chat","revision":1,"node_ids":[destination.state.identity.node_id()],"caller_device_ids":[destination.owner_id],"deployment_ids":[deployment],"router_device_ids":[principal["principal_id"]],"local_only":true,"paused":false,"max_concurrent_requests":1,"max_concurrent_per_caller":1,"max_queued_per_caller":8,"max_queued_requests":16,"max_buffered_bytes":1048576});
    let (status, preview) = destination
        .post(
            &format!("{BASE}/pools/preview"),
            &json!({"expected_revision":0,"policy":policy}),
            false,
        )
        .await;
    assert_eq!(status, StatusCode::OK, "{preview}");
    let (status, result) = destination
        .post(
            &format!("{BASE}/pools/apply"),
            &json!({"preview_id":preview["preview_id"]}),
            true,
        )
        .await;
    assert_eq!(status, StatusCode::OK, "{result}");
    let (status, grant) = destination.post(&format!("{BASE}/router-grants"), &json!({"pool_id":policy["pool_id"],"policy_revision":1,"router_device_id":principal["principal_id"],"caller_device_id":destination.owner_id,"deployment_ids":[deployment],"actions":["reserve","execute","status","cancel"],"expires_in_seconds":3600}), true).await;
    assert_eq!(status, StatusCode::OK, "{grant}");
    let snapshot = transport::request(
        &source.state,
        destination.state.identity.node_id(),
        Method::GET,
        &format!("{BASE}/node-capabilities"),
        axum::body::Bytes::new(),
        None,
    )
    .await
    .unwrap()
    .json()
    .await
    .unwrap();
    assert_eq!(snapshot["deployments"][0]["deployment_id"], deployment);
    let prompt = serde_json::to_vec(&json!({"model":"example/model-32b","messages":[{"role":"user","content":"Test"}],"max_tokens":16})).unwrap();
    let reservation = json!({"grant_id":grant["grant_id"],"pool_id":policy["pool_id"],"caller_device_id":destination.owner_id,"request_id":Uuid::now_v7(),"attempt_id":Uuid::new_v4(),"deployment_id":deployment,"request_sha256":sha256_hex(&prompt),"request_bytes":prompt.len(),"policy_revision":1,"context_budget":4096,"output_budget":16,"lease_seconds":30,"required_capabilities":["text_chat"]});
    let mut wrong = reservation.clone();
    wrong["caller_device_id"] = json!(source.owner_id);
    let response = transport::request(
        &source.state,
        destination.state.identity.node_id(),
        Method::POST,
        &format!("{BASE}/reservations"),
        serde_json::to_vec(&wrong).unwrap().into(),
        Some(Uuid::new_v4()),
    )
    .await
    .unwrap();
    assert_eq!(response.status(), StatusCode::FORBIDDEN);
    let key = Uuid::new_v4();
    let response = transport::request(
        &source.state,
        destination.state.identity.node_id(),
        Method::POST,
        &format!("{BASE}/reservations"),
        serde_json::to_vec(&reservation).unwrap().into(),
        Some(key),
    )
    .await
    .unwrap();
    assert_eq!(response.status(), StatusCode::CREATED);
    let lease = response.json().await.unwrap();
    let replay = transport::request(
        &source.state,
        destination.state.identity.node_id(),
        Method::POST,
        &format!("{BASE}/reservations"),
        serde_json::to_vec(&reservation).unwrap().into(),
        Some(key),
    )
    .await
    .unwrap()
    .json()
    .await
    .unwrap();
    assert_eq!(replay, lease);
    let (status, result) = destination
        .post(
            &format!(
                "{BASE}/router-principals/{}/revoke",
                principal["principal_id"].as_str().unwrap()
            ),
            &json!({}),
            true,
        )
        .await;
    assert_eq!(status, StatusCode::OK, "{result}");
    {
        let conn = destination.state.database.as_ref().unwrap().lock();
        let state: String = conn
            .query_row(
                "SELECT state FROM inference_reservations WHERE reservation_id=?1",
                [lease["reservation_id"].as_str().unwrap()],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(state, "cancelled");
        let revoked: bool = conn
            .query_row(
                "SELECT revoked FROM inference_router_grants WHERE grant_id=?1",
                [grant["grant_id"].as_str().unwrap()],
                |row| row.get(0),
            )
            .unwrap();
        assert!(revoked);
    }
    source.stop().await;
    destination.stop().await;
}
