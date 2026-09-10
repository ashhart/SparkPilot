#[test]
fn symlinked_target_is_never_followed_or_reused() {
    // Remove target symlinks themselves and refetch without reading or writing through them.
    let payload = b"spark weights".to_vec();
    let h = harness(&[]);
    let (files, map) = fixture_files(&[("weights.bin", payload.clone())]);
    let root = h.dir.path().join("models");
    let work = root.join(h.recipe.id()).join(&h.recipe.source.revision);
    std::fs::create_dir_all(&work).unwrap();
    let victim = h.dir.path().join("victim.bin");
    // Use a same-length wrong-content target so size-only verification would incorrectly pass.
    std::fs::write(&victim, b"NOT-WEIGHTS!!").unwrap();
    std::os::unix::fs::symlink(&victim, work.join("weights.bin")).unwrap();

    let coordinator = DownloadCoordinator {
        resolver: Box::new(MemResolver::new(files)),
        source: Box::new(MemSource {
            data: map,
            fail_at: None,
            served: h.served.clone(),
        }),
    };
    let cancel = CancelFlag::new();
    let c = ctx(&root, &cancel, 1 << 40);
    coordinator
        .install(&h.database, &h.recipe, &c, &NullSink, &root)
        .expect("a symlinked target must be removed and downloaded normally");

    assert_eq!(
        h.served.load(Ordering::SeqCst),
        payload.len(),
        "a symlinked target must never be reused"
    );
    let staged_path = work.join("weights.bin");
    assert!(
        std::fs::symlink_metadata(&staged_path)
            .expect("staged target must exist")
            .is_file(),
        "the staged target must be a fresh regular file, not a link"
    );
    assert_eq!(std::fs::read(&staged_path).unwrap(), payload);
    assert_eq!(
        std::fs::read(&victim).unwrap(),
        b"NOT-WEIGHTS!!",
        "the link destination must be untouched"
    );
    let row = sparkd::store::model_row(&h.database.lock(), "example/model-32b")
        .unwrap()
        .unwrap();
    assert_eq!(row.install_state, "installed");
}
