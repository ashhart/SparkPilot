#[test]
fn disk_preflight_blocks_oversized_downloads() {
    let h = harness(&[("weights.bin", vec![7u8; 1024 * 1024])]);
    let (files, map) = fixture_files(&[("weights.bin", vec![7u8; 1024 * 1024])]);
    let coordinator = DownloadCoordinator {
        resolver: Box::new(MemResolver::new(files)),
        source: Box::new(MemSource {
            data: map,
            fail_at: None,
            served: h.served.clone(),
        }),
    };
    let cancel = CancelFlag::new();
    let root = h.dir.path().join("models");
    // Disk that cannot hold required + reserve.
    let c = ctx(&root, &cancel, 10_000);
    let err = coordinator
        .install(&h.database, &h.recipe, &c, &NullSink, &root)
        .unwrap_err();
    assert!(matches!(
        err,
        download::DownloadError::InsufficientDisk { .. }
    ));
    let served = h.served.load(Ordering::SeqCst);
    assert_eq!(served, 0, "nothing is fetched when preflight fails");
    let row = sparkd::store::model_row(&h.database.lock(), "example/model-32b")
        .unwrap()
        .unwrap();
    assert_eq!(row.install_state, "available");
}
