#[tokio::test]
async fn overlay_health_tracks_reachability_and_adopts_a_rotated_address() {
    #[derive(Debug)]
    struct SwitchableOverlay {
        route: Arc<Mutex<Result<Option<PrivateOverlayRoute>, String>>>,
    }
    impl PrivateOverlayProbe for SwitchableOverlay {
        fn route(&self) -> Result<Option<PrivateOverlayRoute>, String> {
            self.route.lock().clone()
        }
    }
    fn present(host: &str) -> Result<Option<PrivateOverlayRoute>, String> {
        Ok(Some(PrivateOverlayRoute {
            provider: "tailscale".into(),
            hostname: host.into(),
            address: Some(host.into()),
        }))
    }

    let route = Arc::new(Mutex::new(present("100.96.4.2")));
    let (base, _client, database, _guard) =
        test_state("owner");
    let service = Arc::new(
        RemoteAccessService::new(database.clone(), base.events.clone(), base.identity.node_id().to_string())
        .with_private_overlay_probe(Arc::new(SwitchableOverlay {
            route: route.clone(),
        })),
    );

    // A reachable overlay enables healthy at its current address.
    let enabled = service.enable("private_overlay").unwrap();
    assert!(enabled.enabled);
    assert_eq!(enabled.mode, "private_overlay");
    assert_eq!(enabled.health, "healthy");
    assert_eq!(enabled.hostname.as_deref(), Some("100.96.4.2"));

    // The interface goes away: degrade and say so.
    *route.lock() = Ok(None);
    assert_eq!(service.refresh_health().unwrap().health, "degraded");

    // It returns at the same address: healthy again.
    *route.lock() = present("100.96.4.2");
    let row = service.refresh_health().unwrap();
    assert_eq!(row.health, "healthy");
    assert_eq!(row.hostname.as_deref(), Some("100.96.4.2"));

    // Keep overlay healthy while adopting a live reassigned 100.64/10 address.
    *route.lock() = present("100.100.7.9");
    let row = service.refresh_health().unwrap();
    assert_eq!(row.health, "healthy");
    assert_eq!(row.hostname.as_deref(), Some("100.100.7.9"));

    // Preserve prior health and hostname on inconclusive probe errors.
    *route.lock() = Err("interface enumeration failed".into());
    let row = service.refresh_health().unwrap();
    assert_eq!(row.health, "healthy");
    assert_eq!(row.hostname.as_deref(), Some("100.100.7.9"));

    // Exactly one unhealthy event across the whole degrade/recover/rotate cycle.
    let unhealthy = {
        let conn = database.lock();
        let mut stmt = conn
            .prepare("SELECT COUNT(*) FROM events WHERE event_type = 'remote.tunnel.unhealthy'")
            .unwrap();
        stmt.query_row([], |row| row.get::<_, i64>(0)).unwrap()
    };
    assert_eq!(unhealthy, 1);

    // BH-16: adopting a reassigned address is not silent; the owner is told which address answers now.
    let adopted = {
        let conn = database.lock();
        let mut stmt = conn
            .prepare("SELECT payload_json FROM events WHERE event_type = 'remote.route.hostname_changed' ORDER BY sequence")
            .unwrap();
        stmt.query_map([], |row| row.get::<_, String>(0))
            .unwrap()
            .collect::<Result<Vec<_>, _>>()
            .unwrap()
    };
    assert_eq!(adopted.len(), 1, "one event for the one address change");
    let payload: serde_json::Value = serde_json::from_str(&adopted[0]).unwrap();
    assert_eq!(payload["was_hostname"], "100.96.4.2");
    assert_eq!(payload["hostname"], "100.100.7.9");
}
