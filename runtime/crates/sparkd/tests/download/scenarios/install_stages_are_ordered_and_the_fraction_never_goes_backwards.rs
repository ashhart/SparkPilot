/// Use multiple files larger than one chunk to expose per-file resets in whole-install progress.
#[test]
fn install_stages_are_ordered_and_the_fraction_never_goes_backwards() {
    let chunk = 8 * 1024 * 1024;
    let payload_a = vec![0xA1_u8; chunk + chunk / 2];
    let payload_b = vec![0xB2_u8; chunk + chunk / 2];
    let h = harness(&[]);
    let (files, map) = fixture_files(&[("a.bin", payload_a.clone()), ("b.bin", payload_b.clone())]);
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
    let sink = RecordingSink::default();

    coordinator
        .install(&h.database, &h.recipe, &c, &sink, &root)
        .unwrap();

    let seen = sink.seen.lock().clone();
    assert!(!seen.is_empty(), "an install reported no stages at all");

    // Compare first-seen stage order because verification interleaves across files.
    let mut order: Vec<String> = Vec::new();
    for (stage, _) in &seen {
        if !order.contains(stage) {
            order.push(stage.clone());
        }
    }
    assert_eq!(
        order,
        vec![
            "disk_preflight",
            "downloading",
            "verifying",
            "materialising"
        ],
        "unexpected stage order: {order:?}"
    );

    // Stages with nothing measurable behind them must not claim a fraction.
    for (stage, progress) in &seen {
        if stage == "disk_preflight" || stage == "materialising" {
            assert!(
                progress.is_none(),
                "{stage} must not claim a fraction, got {progress:?}"
            );
        }
    }

    // Require the whole-install fraction to remain monotonic across file boundaries.
    let fractions: Vec<f64> = seen.iter().filter_map(|(_, p)| *p).collect();
    assert!(
        fractions.len() >= 4,
        "expected several measured points, got {fractions:?}"
    );
    for pair in fractions.windows(2) {
        assert!(
            pair[1] >= pair[0] - 1e-9,
            "install progress went backwards: {} -> {}",
            pair[0],
            pair[1]
        );
    }
    let last = fractions.last().copied().unwrap();
    assert!(
        (last - 1.0).abs() < 1e-9,
        "install ended at {last}, not 1.0"
    );
}
