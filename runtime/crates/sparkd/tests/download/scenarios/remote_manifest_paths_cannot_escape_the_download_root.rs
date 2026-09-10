#[test]
fn remote_manifest_paths_cannot_escape_the_download_root() {
    let h = harness(&[]);
    let bytes = b"owned".to_vec();
    let files = vec![RemoteFile {
        relative_path: "../../outside.txt".into(),
        size_bytes: bytes.len() as u64,
        sha256: sha256_hex(&bytes),
    }];
    let coordinator = DownloadCoordinator {
        resolver: Box::new(MemResolver::new(files)),
        source: Box::new(MemSource {
            data: HashMap::from([("../../outside.txt".into(), bytes)]),
            fail_at: None,
            served: h.served.clone(),
        }),
    };
    let cancel = CancelFlag::new();
    let root = h.dir.path().join("models");
    let c = ctx(&root, &cancel, 1 << 40);

    let error = coordinator
        .install(&h.database, &h.recipe, &c, &NullSink, &root)
        .expect_err("remote traversal must be rejected");

    assert!(matches!(error, download::DownloadError::Source(_)));
    assert!(!h.dir.path().join("outside.txt").exists());
    assert_eq!(h.served.load(Ordering::SeqCst), 0);
}
