#[test]
fn same_size_corrupted_target_is_rejected_and_refetched() {
    // Rehash mutable staged files; correct length does not prove correct content.
    let payload = b"spark weights".to_vec();
    let h = harness(&[]);
    let (files, map) = fixture_files(&[("weights.bin", payload.clone())]);
    let root = h.dir.path().join("models");
    let work = root.join(h.recipe.id()).join(&h.recipe.source.revision);
    std::fs::create_dir_all(&work).unwrap();
    let corrupted: Vec<u8> = payload.iter().map(|byte| byte ^ 0x5a).collect();
    std::fs::write(work.join("weights.bin"), &corrupted).unwrap();

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
        .expect("a corrupted same-size target must be replaced by a clean download");

    assert_eq!(
        h.served.load(Ordering::SeqCst),
        payload.len(),
        "a wrong-digest target must be refetched in full"
    );
    assert_eq!(std::fs::read(work.join("weights.bin")).unwrap(), payload);
    let row = sparkd::store::model_row(&h.database.lock(), "example/model-32b")
        .unwrap()
        .unwrap();
    assert_eq!(row.install_state, "installed");
}
