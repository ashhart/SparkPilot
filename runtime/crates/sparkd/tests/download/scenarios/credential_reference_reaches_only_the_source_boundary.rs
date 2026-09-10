#[test]
fn credential_reference_reaches_only_the_source_boundary() {
    let h = harness(&[("config.json", b"private".to_vec())]);
    let (files, _) = fixture_files(&[("config.json", b"private".to_vec())]);
    let credential_path = h.dir.path().join("provider.secret");
    std::fs::write(&credential_path, "hf_read_only_token").unwrap();
    let coordinator = DownloadCoordinator {
        resolver: Box::new(MemResolver::new(files)),
        source: Box::new(CredentialAwareSource {
            data: b"private".to_vec(),
            expected_credential: credential_path.clone(),
        }),
    };
    let cancel = CancelFlag::new();
    let root = h.dir.path().join("models");
    let c = ctx(&root, &cancel, 1 << 40);

    coordinator
        .install_with_credential(
            &h.database,
            &h.recipe,
            &c,
            &NullSink,
            &root,
            Some(&credential_path),
        )
        .unwrap();
}
