#[test]
fn verified_target_is_reused_without_refetching() {
    // Reuse prior digest-verified complete files and fetch only the missing remainder on retry.
    let h = harness(&[]);
    let (files, map) = fixture_files(&[
        ("done.bin", b"complete".to_vec()),
        ("todo.bin", b"pending".to_vec()),
    ]);
    let root = h.dir.path().join("models");
    let work = root.join(h.recipe.id()).join(&h.recipe.source.revision);
    std::fs::create_dir_all(&work).unwrap();
    std::fs::write(work.join("done.bin"), b"complete").unwrap();

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
        .expect("an already-verified target must be reused, not re-verified from a fresh .part");

    assert_eq!(
        h.served.load(Ordering::SeqCst),
        "pending".len(),
        "only the unfinished file may be fetched"
    );
    for name in ["done.bin", "todo.bin"] {
        assert!(
            root.join("snapshots/example/model-32b/14d7b2f3d8f8f63e000000000000000000000000")
                .join(name)
                .exists(),
            "snapshot must contain {name}"
        );
    }
    let row = sparkd::store::model_row(&h.database.lock(), "example/model-32b")
        .unwrap()
        .unwrap();
    assert_eq!(row.install_state, "installed");
}
