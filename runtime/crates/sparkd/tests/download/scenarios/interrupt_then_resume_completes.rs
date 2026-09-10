#[test]
fn interrupt_then_resume_completes() {
    let h = harness(&[("weights.bin", vec![7u8; 1024 * 1024])]);
    let (files, map) = fixture_files(&[("weights.bin", vec![7u8; 1024 * 1024])]);

    // Attempt 1 fails mid-file after ~300 KiB.
    let fail_source = MemSource {
        data: map.clone(),
        fail_at: Some(300 * 1024),
        served: h.served.clone(),
    };
    let coordinator = DownloadCoordinator {
        resolver: Box::new(MemResolver::new(files.clone())),
        source: Box::new(fail_source),
    };
    let cancel = CancelFlag::new();
    let root = h.dir.path().join("models");
    {
        let c = ctx(&root, &cancel, 1 << 40);
        let result = coordinator.install(&h.database, &h.recipe, &c, &NullSink, &root);
        assert!(result.is_err(), "first attempt must fail mid-file");
    }

    // Partial state remains on disk.
    let work = root.join(h.recipe.id()).join(&h.recipe.source.revision);
    let parts: Vec<_> = std::fs::read_dir(&work).unwrap().collect();
    assert!(parts.iter().any(|p| {
        p.as_ref()
            .unwrap()
            .file_name()
            .to_string_lossy()
            .ends_with(".part")
    }));
    let served_after_failure = h.served.load(Ordering::SeqCst);

    // Attempt 2 resumes: only the missing tail is fetched.
    let good_source = MemSource {
        data: map.clone(),
        fail_at: None,
        served: h.served.clone(),
    };
    let coordinator = DownloadCoordinator {
        resolver: Box::new(MemResolver::new(files)),
        source: Box::new(good_source),
    };
    {
        let c = ctx(&root, &cancel, 1 << 40);
        coordinator
            .install(&h.database, &h.recipe, &c, &NullSink, &root)
            .unwrap();
    }
    let served_after_resume = h.served.load(Ordering::SeqCst);
    let resumed_bytes = served_after_resume - served_after_failure;
    assert!(
        resumed_bytes < (1024 * 1024),
        "resume must not re-fetch the already downloaded prefix (fetched {resumed_bytes})"
    );

    let row = sparkd::store::model_row(&h.database.lock(), "example/model-32b")
        .unwrap()
        .unwrap();
    assert_eq!(row.install_state, "installed");
}
