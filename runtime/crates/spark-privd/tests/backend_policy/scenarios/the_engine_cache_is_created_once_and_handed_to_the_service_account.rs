#[test]
fn the_engine_cache_is_created_once_and_handed_to_the_service_account() {
    use std::os::unix::fs::PermissionsExt;

    let root = tempfile::tempdir().unwrap();
    let cache = root.path().join("engine-cache");
    // Use the current UID to test cache permissions and reuse without requiring privileged chown.
    let probe = root.path().join("uid-probe");
    std::fs::write(&probe, b"").unwrap();
    let probe_metadata = std::fs::metadata(&probe).unwrap();
    let own_uid = std::os::unix::fs::MetadataExt::uid(&probe_metadata);
    let own_gid = std::os::unix::fs::MetadataExt::gid(&probe_metadata);
    let backend = DockerBackend::new("docker", false)
        .with_service_uid(own_uid)
        .with_service_gid(own_gid)
        .with_engine_cache_root(&cache);

    backend.prepare_engine_cache().unwrap();
    std::fs::write(cache.join("compiled.kernel"), b"expensive").unwrap();
    backend.prepare_engine_cache().unwrap();

    assert_eq!(
        std::fs::read(cache.join("compiled.kernel")).unwrap(),
        b"expensive",
        "a second start must not discard what the first one compiled"
    );
    let metadata = std::fs::metadata(&cache).unwrap();
    assert!(metadata.is_dir());
    assert_eq!(metadata.permissions().mode() & 0o777, 0o770);

    // A link where the directory should be is refused rather than followed.
    let elsewhere = root.path().join("elsewhere");
    std::fs::create_dir(&elsewhere).unwrap();
    let linked = root.path().join("linked-cache");
    std::os::unix::fs::symlink(&elsewhere, &linked).unwrap();
    let refused = DockerBackend::new("docker", false)
        .with_service_uid(own_uid)
        .with_service_gid(own_gid)
        .with_engine_cache_root(&linked)
        .prepare_engine_cache()
        .unwrap_err();
    assert!(refused.to_string().contains("not a link"), "{refused}");
}
