#[test]
fn wrong_digest_never_installs_and_cleans_partial() {
    let h = harness(&[("config.json", b"{\"hi\": 1}".to_vec())]);
    let files = vec![RemoteFile {
        relative_path: "config.json".into(),
        size_bytes: 9,
        sha256: "f".repeat(64), // deliberately wrong
    }];
    let map = HashMap::from([("config.json".into(), b"{\"hi\": 1}".to_vec())]);
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
    let c = ctx(&root, &cancel, 1 << 40);
    let err = coordinator
        .install(&h.database, &h.recipe, &c, &NullSink, &root)
        .unwrap_err();
    assert!(matches!(
        err,
        download::DownloadError::DigestMismatch { .. }
    ));

    let row = sparkd::store::model_row(&h.database.lock(), "example/model-32b")
        .unwrap()
        .unwrap();
    assert_eq!(
        row.install_state, "available",
        "wrong digest must never install"
    );
    let part = root
        .join("downloads")
        .join(h.recipe.id())
        .join(&h.recipe.source.revision)
        .join("config.json.part");
    assert!(!part.exists(), "corrupt partial file must be removed");
}
