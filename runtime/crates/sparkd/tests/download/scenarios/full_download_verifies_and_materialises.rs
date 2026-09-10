#[test]
fn full_download_verifies_and_materialises() {
    let h = harness(&[("config.json", b"{\"hi\": 1}".to_vec())]);
    let (files, map) = fixture_files(&[("config.json", b"{\"hi\": 1}".to_vec())]);
    let resolver = MemResolver::new(files);
    let source = MemSource {
        data: map,
        fail_at: None,
        served: h.served.clone(),
    };
    let coordinator = DownloadCoordinator {
        resolver: Box::new(resolver),
        source: Box::new(source),
    };
    let cancel = CancelFlag::new();
    let root = h.dir.path().join("models");
    let c = ctx(&root, &cancel, 1 << 40);
    coordinator
        .install(&h.database, &h.recipe, &c, &NullSink, &root)
        .unwrap();

    let row = sparkd::store::model_row(&h.database.lock(), "example/model-32b")
        .unwrap()
        .unwrap();
    assert_eq!(row.install_state, "installed");
    assert_eq!(row.total_bytes, Some(9));
    assert!(
        root.join(
            "snapshots/example/model-32b/14d7b2f3d8f8f63e000000000000000000000000/config.json"
        )
        .exists()
    );
    // Blob store populated under blobs/sha256/<xx>/<digest>.
    let digest = sha256_hex(b"{\"hi\": 1}");
    assert!(
        root.join("blobs/sha256")
            .join(&digest[..2])
            .join(&digest)
            .exists()
    );
}
