#[test]
fn disk_preflight_uses_the_disk_reserve_not_the_memory_reserve() {
    let payload = vec![7u8; 1024 * 1024];
    let h = harness(&[("weights.bin", payload.clone())]);
    let (files, map) = fixture_files(&[("weights.bin", payload)]);
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
    let mut c = ctx(&root, &cancel, 2 * 1024 * 1024);
    c.disk_reserve_bytes = 512 * 1024;

    coordinator
        .install(&h.database, &h.recipe, &c, &NullSink, &root)
        .expect("the disk policy must not reuse the recipe's memory reserve");
}
