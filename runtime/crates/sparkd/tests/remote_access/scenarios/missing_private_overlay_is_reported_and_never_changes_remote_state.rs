#[tokio::test]
async fn missing_private_overlay_is_reported_and_never_changes_remote_state() {
    #[derive(Debug)]
    struct MissingOverlay;
    impl PrivateOverlayProbe for MissingOverlay {
        fn route(&self) -> Result<Option<PrivateOverlayRoute>, String> {
            Ok(None)
        }
    }

    let (base, client, database, _guard) =
        test_state("owner");
    let service = RemoteAccessService::new(database.clone(), base.events.clone(), base.identity.node_id().to_string())
    .with_private_overlay_probe(Arc::new(MissingOverlay));
    let state = base.with_remote(Arc::new(service));

    let body = preview_enable_body(&state, &client, "private_overlay", None).await;
    let (status, value) = send(
        state.clone(),
        signed_request(
            &client,
            "POST",
            "/api/v1/remote/enable",
            Some(&body),
            vec![],
        ),
    )
    .await;

    assert_eq!(status, StatusCode::CONFLICT);
    assert_eq!(value["error"]["code"], "PRIVATE_OVERLAY_UNAVAILABLE");
    let row = state.remote.as_ref().unwrap().status().unwrap();
    assert!(!row.enabled);
    assert_eq!(row.mode, "disabled");
    let operation_count: i64 = database
        .lock()
        .query_row("SELECT COUNT(*) FROM operations", [], |row| row.get(0))
        .unwrap();
    assert_eq!(operation_count, 0);
}
