#[test]
fn symlinked_oversized_partial_never_truncates_the_link_destination() {
    // Unlink planted partial symlinks without opening or truncating their destinations.
    let payload = b"spark weights".to_vec();
    let h = harness(&[]);
    let (files, map) = fixture_files(&[("weights.bin", payload.clone())]);
    let root = h.dir.path().join("models");
    let work = root.join(h.recipe.id()).join(&h.recipe.source.revision);
    std::fs::create_dir_all(&work).unwrap();
    let victim_bytes = vec![0x5au8; 64]; // oversized vs the 13-byte manifest entry
    let victim = h.dir.path().join("victim.bin");
    std::fs::write(&victim, &victim_bytes).unwrap();
    std::os::unix::fs::symlink(&victim, work.join("weights.bin.part")).unwrap();

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
        .expect("a symlinked partial must be discarded and the file downloaded anew");

    assert_eq!(
        std::fs::read(&victim).unwrap(),
        victim_bytes,
        "the link destination must never be truncated or written through"
    );
    assert_eq!(
        h.served.load(Ordering::SeqCst),
        payload.len(),
        "nothing behind a symlinked partial may be reused"
    );
    let staged_path = work.join("weights.bin");
    assert!(
        std::fs::symlink_metadata(&staged_path)
            .expect("staged target must exist")
            .is_file(),
        "the staged target must be a fresh regular file, not a link"
    );
    assert_eq!(std::fs::read(&staged_path).unwrap(), payload);
    let row = sparkd::store::model_row(&h.database.lock(), "example/model-32b")
        .unwrap()
        .unwrap();
    assert_eq!(row.install_state, "installed");
}
