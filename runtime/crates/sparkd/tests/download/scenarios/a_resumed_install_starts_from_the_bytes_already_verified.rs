/// Start resumed-install progress from signed-manifest bytes already verified on disk.
#[test]
fn a_resumed_install_starts_from_the_bytes_already_verified() {
    let chunk = 8 * 1024 * 1024;
    let payload_a = vec![0xA1_u8; chunk + chunk / 2];
    let payload_b = vec![0xB2_u8; chunk + chunk / 2];
    let h = harness(&[]);
    let (files, map) = fixture_files(&[
        ("done.bin", payload_a.clone()),
        ("todo.bin", payload_b.clone()),
    ]);
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

    // Pre-place the first file exactly as a previous attempt would have.
    let work = root
        .join("example/model-32b")
        .join("14d7b2f3d8f8f63e000000000000000000000000");
    std::fs::create_dir_all(&work).unwrap();
    std::fs::write(work.join("done.bin"), &payload_a).unwrap();

    let c = ctx(&root, &cancel, 1 << 40);
    let sink = RecordingSink::default();
    coordinator
        .install(&h.database, &h.recipe, &c, &sink, &root)
        .unwrap();

    let seen = sink.seen.lock().clone();
    let first_measured = seen
        .iter()
        .find_map(|(stage, progress)| (stage == "downloading").then_some(*progress).flatten())
        .expect("a resumed install still reports a downloading fraction");
    assert!(
        first_measured >= 0.49,
        "a resumed install reported {first_measured}, ignoring the half already verified"
    );
}
