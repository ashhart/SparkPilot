#[test]
fn aggregate_status_can_read_the_configured_mode_without_a_route_probe() {
    struct PanickingOverlay;
    impl PrivateOverlayProbe for PanickingOverlay {
        fn route(&self) -> Result<Option<PrivateOverlayRoute>, String> {
            panic!("the reconnect status path must not perform an overlay probe")
        }
    }

    let (state, _, database, _guard) = test_state("owner");
    let service = RemoteAccessService::new(database, state.events.clone(), state.identity.node_id().to_string())
    .with_private_overlay_probe(Arc::new(PanickingOverlay));

    assert_eq!(service.configured_mode().unwrap(), "disabled");
}
