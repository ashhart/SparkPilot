#[test]
fn oversized_partial_is_truncated_and_one_retry_succeeds() {
    // Truncate oversized stale partials so trailing bytes cannot poison every retry's digest verification.
    let payload = b"spark weights".to_vec();
    let h = harness(&[]);
    let (files, map) = fixture_files(&[("weights.bin", payload.clone())]);
    let root = h.dir.path().join("models");
    let work = root.join(h.recipe.id()).join(&h.recipe.source.revision);
    std::fs::create_dir_all(&work).unwrap();
    let mut stale = payload.clone();
    stale.extend_from_slice(b"STALE-TAIL-FROM-ANOTHER-ATTEMPT");
    std::fs::write(work.join("weights.bin.part"), &stale).unwrap();

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
        .expect("a single retry must recover from an oversized partial");

    let staged_path = work.join("weights.bin");
    assert_eq!(
        std::fs::read(&staged_path).unwrap(),
        payload,
        "no stale trailing bytes may survive the retry"
    );
    assert!(!work.join("weights.bin.part").exists());
    let row = sparkd::store::model_row(&h.database.lock(), "example/model-32b")
        .unwrap()
        .unwrap();
    assert_eq!(row.install_state, "installed");
}
