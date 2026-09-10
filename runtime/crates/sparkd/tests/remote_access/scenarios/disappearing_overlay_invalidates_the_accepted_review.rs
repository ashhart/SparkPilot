#[tokio::test]
async fn disappearing_overlay_invalidates_the_accepted_review() {
    #[derive(Debug)]
    struct SwitchableOverlay {
        route: Arc<Mutex<Option<PrivateOverlayRoute>>>,
    }
    impl PrivateOverlayProbe for SwitchableOverlay {
        fn route(&self) -> Result<Option<PrivateOverlayRoute>, String> {
            Ok(self.route.lock().clone())
        }
    }

    let route = Arc::new(Mutex::new(Some(PrivateOverlayRoute {
        provider: "tailscale".into(),
        hostname: "100.96.4.2".into(),
        address: Some("100.96.4.2".into()),
    })));
    let (base, client, database, _guard) =
        test_state("owner");
    let service = RemoteAccessService::new(database.clone(), base.events.clone(), base.identity.node_id().to_string())
    .with_private_overlay_probe(Arc::new(SwitchableOverlay {
        route: route.clone(),
    }));
    let state = base.with_remote(Arc::new(service));
    let body = preview_enable_body(&state, &client, "private_overlay", None).await;
    *route.lock() = None;

    let (status, value) = send(
        state,
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
    assert_eq!(value["error"]["code"], "PREVIEW_STALE");
    let row_count: i64 = database
        .lock()
        .query_row("SELECT COUNT(*) FROM remote_access", [], |row| row.get(0))
        .unwrap();
    assert_eq!(row_count, 0, "stale review did not persist remote state");
}
