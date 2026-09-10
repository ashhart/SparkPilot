#[tokio::test]
async fn external_import_preview_refuses_non_owner_without_revealing_evidence() {
    let (state, client, _, _guard) =
        test_state("administrator", healthy_report(), CollectiveOutcome::Passed);
    let body = json!({
        "name": "Existing lab",
        "member_node_ids": [uuid::Uuid::new_v4(), uuid::Uuid::new_v4()],
    });
    let (status, value) = send(
        state,
        signed_request(
            &client,
            "POST",
            "/api/v1/cluster/import/preview",
            Some(&body),
        ),
    )
    .await;
    assert_eq!(status, StatusCode::FORBIDDEN);
    assert_eq!(value["error"]["code"], "ROLE_FORBIDDEN");
}
