#[tokio::test]
async fn remote_refresh_endpoint_reconciles_overlay_health_on_demand() {
    #[derive(Debug)]
    struct SwitchableOverlay {
        route: Arc<Mutex<Option<PrivateOverlayRoute>>>,
    }
    impl PrivateOverlayProbe for SwitchableOverlay {
        fn route(&self) -> Result<Option<PrivateOverlayRoute>, String> {
            Ok(self.route.lock().clone())
        }
    }
    fn addr(host: &str) -> Option<PrivateOverlayRoute> {
        Some(PrivateOverlayRoute {
            provider: "tailscale".into(),
            hostname: host.into(),
            address: Some(host.into()),
        })
    }

    let route = Arc::new(Mutex::new(addr("100.96.4.2")));
    let (base, client, _database, _guard) =
        test_state("owner");
    let service = Arc::new(
        RemoteAccessService::new(_database.clone(), base.events.clone(), base.identity.node_id().to_string())
        .with_private_overlay_probe(Arc::new(SwitchableOverlay {
            route: route.clone(),
        })),
    );
    service.enable("private_overlay").unwrap();
    let state = base.with_remote(service);

    // Report route loss on demand without waiting for the thirty-second health ticker.
    *route.lock() = None;
    let (status, value) = send(
        state.clone(),
        signed_request(&client, "POST", "/api/v1/remote/refresh", None, vec![]),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(value["health"], "degraded");

    // Recover health and stored hostname when the overlay returns at a new address.
    *route.lock() = addr("100.100.7.9");
    let (status, value) = send(
        state,
        signed_request(&client, "POST", "/api/v1/remote/refresh", None, vec![]),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(value["health"], "healthy");
    assert_eq!(value["hostname"], "100.100.7.9");
}
