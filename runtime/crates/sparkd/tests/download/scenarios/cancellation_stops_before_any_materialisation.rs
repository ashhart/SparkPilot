#[test]
fn cancellation_stops_before_any_materialisation() {
    let h = harness(&[("config.json", b"x".to_vec())]);
    let (files, map) = fixture_files(&[("config.json", b"data".to_vec())]);
    let coordinator = DownloadCoordinator {
        resolver: Box::new(MemResolver::new(files)),
        source: Box::new(MemSource {
            data: map,
            fail_at: None,
            served: h.served.clone(),
        }),
    };
    let cancel = CancelFlag::new();
    cancel.set();
    let root = h.dir.path().join("models");
    let c = ctx(&root, &cancel, 1 << 40);
    let err = coordinator
        .install(&h.database, &h.recipe, &c, &NullSink, &root)
        .unwrap_err();
    assert!(matches!(err, download::DownloadError::Cancelled));
    let row = sparkd::store::model_row(&h.database.lock(), "example/model-32b")
        .unwrap()
        .unwrap();
    assert_eq!(
        row.install_state, "available",
        "cancelled download must not install"
    );
}
